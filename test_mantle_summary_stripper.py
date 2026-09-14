"""Unit tests for concern 3 (reasoning.summary stripper) in bedrock_ctx_stripper.

Runs without litellm installed: the litellm imports are stubbed before import,
same trick as test_cache_ttl_promoter.py.

    python3 test_mantle_summary_stripper.py
"""
import asyncio
import importlib
import os
import sys
import types


def _stub_litellm():
    for name in list(sys.modules):
        if name == "litellm" or name.startswith("litellm."):
            del sys.modules[name]

    litellm = types.ModuleType("litellm")

    integrations = types.ModuleType("litellm.integrations")
    custom_logger = types.ModuleType("litellm.integrations.custom_logger")

    class CustomLogger:  # minimal stand-in
        pass

    custom_logger.CustomLogger = CustomLogger

    proxy = types.ModuleType("litellm.proxy")
    proxy_server = types.ModuleType("litellm.proxy.proxy_server")
    proxy_server.DualCache = type("DualCache", (), {})
    proxy_server.UserAPIKeyAuth = type("UserAPIKeyAuth", (), {})

    types_mod = types.ModuleType("litellm.types")
    types_utils = types.ModuleType("litellm.types.utils")
    types_utils.CallTypesLiteral = str

    sys.modules.update({
        "litellm": litellm,
        "litellm.integrations": integrations,
        "litellm.integrations.custom_logger": custom_logger,
        "litellm.proxy": proxy,
        "litellm.proxy.proxy_server": proxy_server,
        "litellm.types": types_mod,
        "litellm.types.utils": types_utils,
    })


def load(**env):
    """(Re)import the hook module with a specific env."""
    # In this repo the callback lives under config/callbacks/ (it is uploaded to
    # S3 and downloaded into the container's cwd at startup, which is why the
    # module name is flat).
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "config", "callbacks"))
    for key in [
        "MANTLE_DROP_REASONING_SUMMARY_ENABLED",
        "MANTLE_DROP_REASONING_SUMMARY_MODELS",
        "CACHE_TTL_PROMOTE_ENABLED",
    ]:
        os.environ.pop(key, None)
    os.environ.update(env)
    _stub_litellm()
    sys.modules.pop("bedrock_ctx_stripper", None)
    return importlib.import_module("bedrock_ctx_stripper")


def call(mod, data, call_type="aresponses"):
    hook = mod.bedrock_ctx_stripper_instance
    return asyncio.run(hook.async_pre_call_hook(
        user_api_key_dict=None, cache=None, data=data, call_type=call_type,
    ))


ON = {"MANTLE_DROP_REASONING_SUMMARY_ENABLED": "true"}
results = []


def check(name, cond):
    results.append((name, bool(cond)))
    print(("  PASS  " if cond else "  FAIL  ") + name)


print("== concern 3: reasoning.summary stripper ==")

# --- the actual production bug: ChatGPT app sends summary=detailed ---
mod = load(**ON)
out = call(mod, {"model": "gpt-6-astra", "input": "hi",
                "reasoning": {"effort": "medium", "summary": "detailed"}})
check("detailed -> summary removed", "summary" not in out["reasoning"])
check("detailed -> effort preserved", out["reasoning"]["effort"] == "medium")

out = call(mod, {"model": "gpt-6-astra", "reasoning": {"summary": "concise"}})
check("concise+no effort -> whole reasoning dropped (Mantle 400s on {})",
      "reasoning" not in out)

out = call(mod, {"model": "gpt-6-astra", "reasoning": {"effort": "low", "summary": "auto"}})
check("auto also stripped (idempotent with litellm's own behavior)",
      "summary" not in out["reasoning"])

# --- must not touch anything else ---
out = call(mod, {"model": "gpt-6-astra", "input": "hi", "reasoning": {"effort": "high"},
                 "tools": [{"type": "function", "name": "f"}], "store": False})
check("no summary key -> request untouched",
      out["reasoning"] == {"effort": "high"} and out["tools"][0]["name"] == "f"
      and out["store"] is False)

out = call(mod, {"model": "claude-fable-5", "reasoning": {"summary": "detailed"}})
check("out-of-scope model untouched (allowlist=astra)",
      out["reasoning"]["summary"] == "detailed")

out = call(mod, {"model": "gpt-6-astra", "reasoning": {"summary": "detailed"}},
           call_type="acompletion")
check("non-Responses route untouched", out["reasoning"]["summary"] == "detailed")

out = call(mod, {"model": "gpt-6-astra", "reasoning": {"summary": "detailed"}},
           call_type="responses")
check("sync 'responses' route also handled", "reasoning" not in out)

# --- default must be OFF (shared S3 object cannot be canaried) ---
mod_off = load()
out = call(mod_off, {"model": "gpt-6-astra", "reasoning": {"summary": "detailed"}})
check("DEFAULT OFF (env absent -> no rewrite)", out["reasoning"]["summary"] == "detailed")

# --- malformed / hostile shapes must never raise ---
mod = load(**ON)
for label, data in [
    ("reasoning=None", {"model": "gpt-6-astra", "reasoning": None}),
    ("reasoning=str", {"model": "gpt-6-astra", "reasoning": "detailed"}),
    ("reasoning=list", {"model": "gpt-6-astra", "reasoning": [{"summary": "x"}]}),
    ("no model key", {"reasoning": {"summary": "detailed"}}),
    ("empty dict", {}),
]:
    try:
        call(mod, data)
        check(f"malformed tolerated: {label}", True)
    except Exception as exc:  # noqa: BLE001
        check(f"malformed tolerated: {label} ({exc!r})", False)

# --- idempotency: running twice is a no-op the second time ---
data = {"model": "gpt-6-astra", "reasoning": {"effort": "low", "summary": "detailed"}}
call(mod, data)
snapshot = dict(data["reasoning"])
call(mod, data)
check("idempotent", data["reasoning"] == snapshot)

# --- custom allowlist honored ---
mod = load(MANTLE_DROP_REASONING_SUMMARY_ENABLED="true",
           MANTLE_DROP_REASONING_SUMMARY_MODELS="gpt-5.6-sol")
out = call(mod, {"model": "gpt-6-astra", "reasoning": {"summary": "detailed"}})
check("custom allowlist excludes astra", out["reasoning"]["summary"] == "detailed")
out = call(mod, {"model": "bedrock_mantle/openai.gpt-5.6-sol", "reasoning": {"summary": "detailed"}})
check("custom allowlist includes sol", "reasoning" not in out)

# --- concern 1 + 2 regression: existing behavior still intact ---
mod = load(CACHE_TTL_PROMOTE_ENABLED="true", **ON)
out = call(mod, {"model": "claude-fable-5", "context_management": {"edits": []},
                 "messages": [{"role": "user", "content": [
                     {"type": "text", "text": "x",
                      "cache_control": {"type": "ephemeral"}}]}]},
           call_type="anthropic_messages")
check("concern 1 still strips context_management", "context_management" not in out)
check("concern 2 still promotes ttl to 1h",
      out["messages"][0]["content"][0]["cache_control"].get("ttl") == "1h")

failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed")
if failed:
    print("FAILED: " + "; ".join(failed))
sys.exit(1 if failed else 0)
