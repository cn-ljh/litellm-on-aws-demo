#!/usr/bin/env bash
# 同步 Tavily + Exa MCP server 到 LiteLLM DB
#
# 使用场景：
#   - 首次部署后初始化（CFN 创建 secret + ECS 启动 LiteLLM 后跑一次）
#   - rotation API key 后重新写入
#   - DB 里 server 被误删后恢复
#
# 前置条件：
#   - Secrets Manager 已写入 litellm/<TENANT>/tavily 和 litellm/<TENANT>/exa
#   - 本机 AWS CLI 有读权限
#   - LITELLM_PROXY_URL 指向已运行的 LiteLLM proxy (例如 https://litellm.example.com)
#
# 用法：
#   PROJECT_NAME=litellm-gw TENANT_NAME=default \
#   LITELLM_PROXY_URL=https://litellm.lijinhong.cn \
#   ./scripts/sync-mcp-servers.sh
#
# 幂等：会先 GET 现有 server，重名（server_name=tavily / exa）则先 DELETE 再 CREATE。

set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
TENANT_NAME="${TENANT_NAME:-default}"
REGION="${AWS_REGION:-us-east-1}"
LITELLM_PROXY_URL="${LITELLM_PROXY_URL:?LITELLM_PROXY_URL is required, e.g. https://litellm.lijinhong.cn}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 拿 master key
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "litellm/${TENANT_NAME}/master-key" \
  --region "$REGION" --query "SecretString" --output text \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['master_key'])")

# 拿 Tavily / Exa key
TAVILY_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "litellm/${TENANT_NAME}/tavily" \
  --region "$REGION" --query "SecretString" --output text \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['api_key'])")
EXA_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "litellm/${TENANT_NAME}/exa" \
  --region "$REGION" --query "SecretString" --output text \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['api_key'])")

[ -z "$TAVILY_KEY" ] && { log "ERROR: Tavily API key empty"; exit 1; }
[ -z "$EXA_KEY" ] && { log "ERROR: Exa API key empty"; exit 1; }
log "Loaded keys (Tavily ${#TAVILY_KEY} chars, Exa ${#EXA_KEY} chars)"

# 删除已存在的同名 server（幂等）
delete_if_exists() {
  local name="$1"
  local existing_id
  existing_id=$(curl -sS "${LITELLM_PROXY_URL}/v1/mcp/server" \
    -H "Authorization: Bearer ${MASTER_KEY}" --max-time 15 \
    | python3 -c "
import sys,json
data=json.load(sys.stdin)
servers=data if isinstance(data,list) else data.get('servers',[])
for s in servers:
    if s.get('server_name')=='${name}' or s.get('alias')=='${name}':
        print(s['server_id']); break
")
  if [ -n "$existing_id" ]; then
    log "Deleting existing ${name} (server_id=${existing_id})"
    curl -sS -X DELETE "${LITELLM_PROXY_URL}/v1/mcp/server/${existing_id}" \
      -H "Authorization: Bearer ${MASTER_KEY}" --max-time 15 > /dev/null
  fi
}

create_server() {
  local payload="$1"
  curl -sS -X POST "${LITELLM_PROXY_URL}/v1/mcp/server" \
    -H "Authorization: Bearer ${MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" --max-time 15 \
    | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'server_id' in d:
    print(f\"  -> server_id={d['server_id']} (status={d.get('status','unknown')})\")
else:
    print(f\"  -> ERROR: {json.dumps(d)[:300]}\"); sys.exit(1)
"
}

# Tavily：用 static_headers 注入 Authorization: Bearer <key>
# （注意：1.85.2 上 auth_type=bearer_token 时 authentication_token 不会被持久化，
#  必须用 static_headers 才能保留 token）
log "Syncing tavily..."
delete_if_exists "tavily"
create_server "$(python3 -c "
import json
print(json.dumps({
    'server_name': 'tavily',
    'alias': 'tavily',
    'description': 'Tavily real-time web search and content extraction',
    'url': 'https://mcp.tavily.com/mcp/',
    'transport': 'http',
    'static_headers': {'Authorization': 'Bearer $TAVILY_KEY'},
    'allow_all_keys': True,
}))")"

# Exa：用 static_headers 注入 x-api-key
log "Syncing exa..."
delete_if_exists "exa"
create_server "$(python3 -c "
import json
print(json.dumps({
    'server_name': 'exa',
    'alias': 'exa',
    'description': 'Exa AI-optimized web search, code search, and company research',
    'url': 'https://mcp.exa.ai/mcp',
    'transport': 'http',
    'static_headers': {'x-api-key': '$EXA_KEY'},
    'allow_all_keys': True,
}))")"

log "Waiting 30s for LiteLLM to refresh registry from DB..."
sleep 30

log "Verifying tools/list..."
TOOLS_COUNT=$(curl -sS -X POST "${LITELLM_PROXY_URL}/mcp/" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  --max-time 60 2>&1 \
  | grep '^data:' | sed 's/^data: //' \
  | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line.startswith('{'): continue
    d=json.loads(line)
    print(len(d.get('result',{}).get('tools',[])))
    break
")

if [ "${TOOLS_COUNT:-0}" -ge 7 ]; then
  log "SUCCESS: ${TOOLS_COUNT} tools available (expected 7: 5 tavily + 2 exa)"
else
  log "WARNING: only ${TOOLS_COUNT} tools visible (expected 7). Check logs."
  exit 1
fi
