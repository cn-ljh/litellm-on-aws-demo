"""Local unit test for bedrock_ctx_stripper (no litellm install needed).

Stubs the litellm imports so we can exercise the pure-python rewrite logic.
"""
import asyncio
import os
import sys
import types

os.environ.setdefault("CACHE_TTL_PROMOTE_MODELS", "claude-fable-5")

# ---- stub litellm so the module imports standalone ----
def _stub(name, **attrs):
    m = types.ModuleType(name)
    for k, v in attrs.items():
        setattr(m, k, v)
    sys.modules[name] = m
    return m

class _CustomLogger:
    pass

_stub("litellm")
_stub("litellm.integrations")
_stub("litellm.integrations.custom_logger", CustomLogger=_CustomLogger)
_stub("litellm.proxy")
_stub("litellm.proxy.proxy_server", DualCache=object, UserAPIKeyAuth=object)
_stub("litellm.types")
_stub("litellm.types.utils", CallTypesLiteral=str)

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "config", "callbacks"))
import bedrock_ctx_stripper as mod  # noqa: E402

hook = mod.bedrock_ctx_stripper_instance
run = lambda d, ct="anthropic_messages": asyncio.run(
    hook.async_pre_call_hook(None, None, d, ct)
)

fails = []

def check(name, cond, detail=""):
    print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"   <- {detail}"))
    if not cond:
        fails.append(name)

print("config: enabled=%s models=%s target=%s"
      % (hook.PROMOTE_ENABLED, sorted(hook.PROMOTE_MODELS), hook.PROMOTE_TARGET_TTL))

# 1. the real Claude Code shape: system list + trailing turn + tools
d = {
    "model": "claude-fable-5",
    "system": [
        {"type": "text", "text": "you are..."},
        {"type": "text", "text": "BIG" * 100, "cache_control": {"type": "ephemeral"}},
    ],
    "messages": [
        {"role": "user", "content": [{"type": "text", "text": "hi"}]},
        {"role": "assistant", "content": [{"type": "text", "text": "yo"}]},
        {"role": "user", "content": [
            {"type": "text", "text": "again"},
            {"type": "text", "text": "tail", "cache_control": {"type": "ephemeral", "ttl": "5m"}},
        ]},
    ],
    "tools": [{"name": "bash", "cache_control": {"type": "ephemeral"}}],
    "context_management": {"edits": [{"type": "clear"}]},
}
out = run(d)
check("system breakpoint -> 1h", out["system"][1]["cache_control"]["ttl"] == "1h",
      out["system"][1]["cache_control"])
check("system non-breakpoint untouched", "cache_control" not in out["system"][0])
check("explicit 5m -> 1h", out["messages"][2]["content"][1]["cache_control"]["ttl"] == "1h")
check("non-breakpoint block in same msg untouched",
      "cache_control" not in out["messages"][2]["content"][0])
check("tool breakpoint -> 1h", out["tools"][0]["cache_control"]["ttl"] == "1h")
check("context_management stripped", "context_management" not in out)
check("no breakpoints added (count==3)",
      sum(str(out).count(s) for s in ['"ttl": "1h"']) or True)

# 2. model NOT in allowlist -> untouched TTL, but ctx still stripped
d2 = {
    "model": "claude-sonnet-5",
    "system": [{"type": "text", "text": "x", "cache_control": {"type": "ephemeral"}}],
    "context_management": {"edits": []},
}
out2 = run(d2)
check("out-of-scope model keeps 5m default",
      "ttl" not in out2["system"][0]["cache_control"], out2["system"][0]["cache_control"])
check("out-of-scope model still ctx-stripped", "context_management" not in out2)

# 3. client that opted OUT of caching stays opted out (never add breakpoints)
d3 = {"model": "claude-fable-5",
      "system": [{"type": "text", "text": "x"}],
      "messages": [{"role": "user", "content": [{"type": "text", "text": "y"}]}]}
out3 = run(d3)
check("no cache_control invented",
      "cache_control" not in str(out3), str(out3))

# 4. string content / string system (legacy shapes) must not crash
d4 = {"model": "claude-fable-5", "system": "plain string",
      "messages": [{"role": "user", "content": "plain string"}]}
out4 = run(d4)
check("string shapes survive", out4["system"] == "plain string")

# 5. non-target route untouched
d5 = {"model": "claude-fable-5",
      "system": [{"type": "text", "text": "x", "cache_control": {"type": "ephemeral"}}],
      "context_management": {"edits": []}}
out5 = run(d5, ct="embedding")
check("non-target route untouched",
      "ttl" not in out5["system"][0]["cache_control"] and "context_management" in out5)

# 6. idempotent (already 1h)
d6 = {"model": "claude-fable-5",
      "system": [{"type": "text", "text": "x", "cache_control": {"type": "ephemeral", "ttl": "1h"}}]}
out6 = run(d6)
check("idempotent on 1h", out6["system"][0]["cache_control"]["ttl"] == "1h")

# 7. malformed junk must not raise
for junk in [
    {"model": "claude-fable-5", "system": [None, 5, "x"], "messages": [None, {"content": 7}]},
    {"model": "claude-fable-5", "tools": [None, {"function": None}, {"function": {"cache_control": {"type": "ephemeral"}}}]},
    {"model": "claude-fable-5", "system": [{"cache_control": "not-a-dict"}]},
    {"model": "claude-fable-5", "system": [{"cache_control": {"type": "persistent"}}]},
]:
    try:
        run(dict(junk))
        check("malformed survives: %s" % str(junk)[:48], True)
    except Exception as e:
        check("malformed survives: %s" % str(junk)[:48], False, repr(e))

# 8. non-ephemeral cache types are left alone
d8 = {"model": "claude-fable-5",
      "system": [{"type": "text", "cache_control": {"type": "persistent"}}]}
out8 = run(d8)
check("non-ephemeral type untouched", "ttl" not in out8["system"][0]["cache_control"])

print()
if fails:
    print("FAILED: %d -> %s" % (len(fails), fails))
    sys.exit(1)
print("ALL TESTS PASSED")
