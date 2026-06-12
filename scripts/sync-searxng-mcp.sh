#!/usr/bin/env bash
# 同步 searxng MCP server 到 LiteLLM DB（与 sync-mcp-servers.sh 同模式）
#
# searxng-mcp 是部署在 litellm-gw-cluster 里的内部服务（cfn/07-searxng-mcp.yaml），
# LiteLLM 通过 Cloud Map 私有 DNS 直连，无需 API key（SG 限制只有 LiteLLM 任务能访问）。
#
# 用法：
#   LITELLM_PROXY_URL=https://litellm.lijinhong.cn ./scripts/sync-searxng-mcp.sh
#
# 幂等：重名（server_name=searxng）则先 DELETE 再 CREATE。

set -euo pipefail

TENANT_NAME="${TENANT_NAME:-default}"
REGION="${AWS_REGION:-us-east-1}"
LITELLM_PROXY_URL="${LITELLM_PROXY_URL:?LITELLM_PROXY_URL is required}"
SEARXNG_MCP_URL="${SEARXNG_MCP_URL:-http://searxng-mcp.litellm-gw.internal:8000/mcp}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "litellm/${TENANT_NAME}/master-key" \
  --region "$REGION" --query "SecretString" --output text \
  | python3 -c "import sys,json;print(json.load(sys.stdin)['master_key'])")

# 删除已存在的同名 server（幂等）
existing_id=$(curl -sS "${LITELLM_PROXY_URL}/v1/mcp/server" \
  -H "Authorization: Bearer ${MASTER_KEY}" --max-time 15 \
  | python3 -c "
import sys,json
data=json.load(sys.stdin)
servers=data if isinstance(data,list) else data.get('servers',[])
for s in servers:
    if s.get('server_name')=='searxng' or s.get('alias')=='searxng':
        print(s['server_id']); break
")
if [ -n "$existing_id" ]; then
  log "Deleting existing searxng (server_id=${existing_id})"
  curl -sS -X DELETE "${LITELLM_PROXY_URL}/v1/mcp/server/${existing_id}" \
    -H "Authorization: Bearer ${MASTER_KEY}" --max-time 15 > /dev/null
fi

log "Creating searxng MCP server (url=${SEARXNG_MCP_URL})..."
curl -sS -X POST "${LITELLM_PROXY_URL}/v1/mcp/server" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
print(json.dumps({
    'server_name': 'searxng',
    'alias': 'searxng',
    'description': 'Self-hosted SearXNG web search (public engines aggregation, no API key)',
    'url': '${SEARXNG_MCP_URL}',
    'transport': 'http',
    'allow_all_keys': True,
}))")" --max-time 30 \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'server_id' in d:
    print(f\"  -> server_id={d['server_id']} (status={d.get('status','unknown')})\")
else:
    print(f\"  -> ERROR: {json.dumps(d)[:300]}\"); sys.exit(1)
"

log "Waiting 30s for LiteLLM to refresh registry from DB..."
sleep 30

log "Verifying searxng tool via tools/list..."
curl -sS -X POST "${LITELLM_PROXY_URL}/mcp/" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "x-mcp-servers: searxng" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  --max-time 60 \
  | grep '^data:' | sed 's/^data: //' \
  | python3 -c "
import sys,json
for line in sys.stdin:
    line=line.strip()
    if not line.startswith('{'): continue
    d=json.loads(line)
    tools=[t['name'] for t in d.get('result',{}).get('tools',[])]
    print(f'searxng tools: {tools}')
    sys.exit(0 if any('web_search' in t for t in tools) else 1)
"
log "SUCCESS: searxng MCP registered and tool visible"
