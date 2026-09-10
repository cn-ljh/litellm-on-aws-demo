"""
LiteLLM custom pre-call hooks for the Bedrock lane.

Two concerns, one hook class (single callback slot in config.yaml):

1. `context_management` stripper (2026-04-21)
   Strip Claude Code's `context_management` parameter before requests hit
   Bedrock (Bedrock rejects it with ``Extra inputs are not permitted``).

2. `cache_control` TTL promoter (2026-09-10)
   Rewrite client-supplied 5-minute prompt-cache breakpoints to the 1-hour
   cache for long agentic sessions. See rationale below.
"""
import logging
import os
from typing import Any, Dict, List, Optional

from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy.proxy_server import DualCache, UserAPIKeyAuth
from litellm.types.utils import CallTypesLiteral
import litellm


logger = logging.getLogger("litellm.proxy")


def _parse_csv_env(name: str, default: str) -> frozenset:
    raw = os.getenv(name, default) or ""
    return frozenset(p.strip() for p in raw.split(",") if p.strip())


class BedrockContextManagementStripper(CustomLogger):
    """Pre-call fixups for Bedrock-routed requests on /v1/messages.

    --- Concern 1: context_management ---
    Claude Code 2.1.116+ auto-injects `context_management: {edits: [...]}`
    without a client-side opt-out, so we have to handle it proxy-side.

    --- Concern 2: prompt cache TTL promotion ---
    Claude Code marks its own `cache_control: {"type": "ephemeral"}` breakpoints,
    which means Anthropic's *5 minute* ephemeral cache. For long agentic coding
    sessions the human thinks/reads between turns, so a large fraction of turns
    land after the 5m window expires and the entire prefix is re-written at the
    1.25x cache-write rate.

    Measured on claude-fable-5, 2026-09-08..09-10 (session 8ae97d72, 211 reqs):
      - turns with gap <= 5m : 147 reqs, cache_write 0.26M tok  -> $102.88
      - turns with gap  > 5m :  63 reqs, cache_write 33.76M tok -> $431.79
      cache_creation_cost was 79.6% of total spend; output was only $15.99.
      Replaying the same traffic against a 1h TTL: $563.22 -> $276.68 (-50.9%),
      expired rewrites 72 -> 14.

    We cannot use litellm's built-in `enable_anthropic_prompt_caching` +
    `anthropic_prompt_caching_ttl: 1h` for this: that path *stands down* whenever
    the request already carries client-supplied cache_control
    (AnthropicCacheControlHook._request_has_cache_control -> get_default_injection_points
    returns []). Claude Code always sets its own, so the flag is a no-op for our
    traffic. Hence we rewrite the client's breakpoints in-place here.

    Bedrock accepts `ttl: "1h"` on us.anthropic.claude-* with no
    `anthropic-beta: extended-cache-ttl-*` header required (verified 2026-09-10:
    response usage reported ephemeral_1h_input_tokens=4004, 5m bucket 0).

    Trade-off / when this LOSES money: a 1h write costs 2.0x base vs 1.25x for
    5m. A turn whose next follow-up never arrives within the hour pays 60% more
    than it would have. That is why this is scoped to an explicit model
    allowlist (CACHE_TTL_PROMOTE_MODELS) rather than applied gateway-wide, and
    why it is killable via env without a code deploy.
    """

    ROUTES_TO_STRIP = {"anthropic_messages", "completion", "acompletion"}

    # Kill switch + blast-radius controls (env, no code deploy needed to change).
    #   CACHE_TTL_PROMOTE_ENABLED=true       -> enable (DEFAULT OFF, see below)
    #   CACHE_TTL_PROMOTE_MODELS=a,b         -> only promote these model aliases
    #                                           (substring match, empty = all)
    #   CACHE_TTL_PROMOTE_TARGET=1h|5m       -> target TTL
    #
    # Defaults OFF on purpose. blue and green both download the *same* S3 key
    # (bedrock_ctx_stripper.py) at container start, so the file cannot be
    # canaried by itself - a green task replacement would silently pick up new
    # code. Keeping the default off makes the S3 upload inert and moves the
    # actual enablement into the task definition env, which IS per-lane.
    PROMOTE_ENABLED = os.getenv("CACHE_TTL_PROMOTE_ENABLED", "false").lower() == "true"
    PROMOTE_MODELS = _parse_csv_env("CACHE_TTL_PROMOTE_MODELS", "claude-fable-5")
    PROMOTE_TARGET_TTL = os.getenv("CACHE_TTL_PROMOTE_TARGET", "1h")

    # ---------- concern 2 helpers ----------

    def _model_in_scope(self, model: str) -> bool:
        if not self.PROMOTE_MODELS:
            return True
        return any(m in model for m in self.PROMOTE_MODELS)

    def _promote_block(self, block: Any) -> int:
        """Promote one content block's cache_control TTL. Returns 1 if changed."""
        if not isinstance(block, dict):
            return 0
        cc = block.get("cache_control")
        if not isinstance(cc, dict):
            return 0
        if cc.get("type") != "ephemeral":
            return 0
        if cc.get("ttl") == self.PROMOTE_TARGET_TTL:
            return 0
        cc["ttl"] = self.PROMOTE_TARGET_TTL
        return 1

    def _promote_content(self, content: Any) -> int:
        if isinstance(content, list):
            return sum(self._promote_block(b) for b in content)
        return 0

    def _promote_request(self, data: Dict[str, Any]) -> int:
        """Walk system / messages / tools and promote every ephemeral breakpoint.

        Note we only ever *rewrite* an existing breakpoint - we never add one.
        Anthropic's 4-block cache_control limit is therefore untouched, and a
        client that opted out of caching stays opted out.
        """
        changed = 0

        system = data.get("system")
        changed += self._promote_content(system)

        messages = data.get("messages")
        if isinstance(messages, list):
            for msg in messages:
                if isinstance(msg, dict):
                    changed += self._promote_content(msg.get("content"))

        tools = data.get("tools")
        if isinstance(tools, list):
            for tool in tools:
                if not isinstance(tool, dict):
                    continue
                # Anthropic shape: cache_control at top level.
                changed += self._promote_block(tool)
                # OpenAI shape: nested under "function".
                changed += self._promote_block(tool.get("function"))

        return changed

    # ---------- hook ----------

    async def async_pre_call_hook(
        self,
        user_api_key_dict: UserAPIKeyAuth,
        cache: DualCache,
        data: dict,
        call_type: CallTypesLiteral,
    ) -> Optional[dict]:
        if call_type not in self.ROUTES_TO_STRIP:
            return data

        model = (data or {}).get("model", "")

        # --- concern 1: context_management ---
        # Only strip when the upstream is a Bedrock route.
        # LiteLLM model identifiers look like `bedrock/...` or `bedrock/converse/...`
        # but the proxy-facing model_name (alias) might be e.g. "claude-sonnet-4-6"
        # -> we strip unconditionally when context_management is present; it's safe
        # because Anthropic API ignores unknown fields transparently and we're not
        # losing information (the beta is only honored by Anthropic's own API for
        # now, and even Bedrock ignores it silently once stripped).
        if "context_management" in data:
            data.pop("context_management", None)
            logger.info(
                "[bedrock_ctx_stripper] stripped context_management from %s (model=%s)",
                call_type, model
            )

        # --- concern 2: cache_control TTL promotion ---
        if self.PROMOTE_ENABLED and self._model_in_scope(model):
            try:
                promoted = self._promote_request(data)
                if promoted:
                    logger.info(
                        "[cache_ttl_promoter] promoted %d cache_control block(s) to ttl=%s "
                        "on %s (model=%s)",
                        promoted, self.PROMOTE_TARGET_TTL, call_type, model
                    )
            except Exception:  # never let a cost optimization break a request
                logger.exception(
                    "[cache_ttl_promoter] failed on %s (model=%s); passing request through",
                    call_type, model
                )

        return data


# Module-level instance — referenced in config.yaml as
#   callbacks: ["bedrock_ctx_stripper.bedrock_ctx_stripper_instance"]
bedrock_ctx_stripper_instance = BedrockContextManagementStripper()
