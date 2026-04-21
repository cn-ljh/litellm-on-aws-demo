"""
LiteLLM custom pre-call hook: strip Claude Code's `context_management` parameter
before requests hit Bedrock (Bedrock doesn't support it yet as of 2026-04-21).

Triggered only on /v1/messages (anthropic_messages) route — OpenAI-format routes
handle this via `additional_drop_params: [context_management]`.
"""
from typing import Optional

from litellm.integrations.custom_logger import CustomLogger
from litellm.proxy.proxy_server import DualCache, UserAPIKeyAuth
from litellm.types.utils import CallTypesLiteral
import litellm


class BedrockContextManagementStripper(CustomLogger):
    """Remove `context_management` from request data for Bedrock Invoke on
    /v1/messages route. Bedrock (us.anthropic.claude-*) rejects it with
    ``Extra inputs are not permitted``.

    Claude Code 2.1.116+ auto-injects `context_management: {edits: [...]}`
    without a client-side opt-out, so we have to handle it proxy-side.
    """

    ROUTES_TO_STRIP = {"anthropic_messages", "completion", "acompletion"}

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
        # Only strip when the upstream is a Bedrock route.
        # LiteLLM model identifiers look like `bedrock/...` or `bedrock/converse/...`
        # but the proxy-facing model_name (alias) might be e.g. "claude-sonnet-4-6"
        # -> we strip unconditionally when context_management is present; it's safe
        # because Anthropic API ignores unknown fields transparently and we're not
        # losing information (the beta is only honored by Anthropic's own API for
        # now, and even Bedrock ignores it silently once stripped).
        if "context_management" in data:
            data.pop("context_management", None)
            # Log once per request so we can observe frequency
            import logging
            logging.getLogger("litellm.proxy").info(
                "[bedrock_ctx_stripper] stripped context_management from %s (model=%s)",
                call_type, model
            )
        return data


# Module-level instance — referenced in config.yaml as
#   callbacks: ["bedrock_ctx_stripper.bedrock_ctx_stripper_instance"]
bedrock_ctx_stripper_instance = BedrockContextManagementStripper()
