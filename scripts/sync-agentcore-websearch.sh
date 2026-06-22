#!/usr/bin/env bash
# 注册 AgentCore Web Search Tool MCP server 到 LiteLLM DB
#
# 这是 AWS Bedrock AgentCore 托管的 Web Search 工具（GA 2026-06-17），通过
# AgentCore Gateway 暴露为 MCP，LiteLLM 用 auth_type=aws_sigv4 + ECS task role
# 签名调用。与自建 SearXNG MCP (sync-searxng-mcp.sh) 并存，不替换。
#
# 前置条件：
#   - 已部署 cfn/08-agentcore-websearch.yaml（或等价的命令式资源）
#     -> AgentCore Gateway (AWS_IAM) + Web Search target + task role InvokeGateway 权限
#   - LiteLLM >= v1.80.18（aws_sigv4 MCP auth），生产是 1.85.2 ✓
#   - 本机 AWS CLI 有 Secrets Manager 读权限
#
# 用法：
#   PROJECT_NAME=litellm-gw TENANT_NAME=default \
#   GATEWAY_ID=litellm-websearch-gw-bruuub19gv \
#   LITELLM_PROXY_URL=https://litellm.lijinhong.cn \
#   ./scripts/sync-agentcore-websearch.sh
#
# 幂等：重名 (agentcore_websearch) 先 DELETE 再 CREATE。

set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
TENANT_NAME="${TENANT_NAME:-default}"
REGION="${AWS_REGION:-us-east-1}"
GATEWAY_ID="${GATEWAY_ID:?GATEWAY_ID is required, e.g. litellm-websearch-gw-xxxxxxxx}"
LITELLM_PROXY_URL="${LITELLM_PROXY_URL:?LITELLM_PROXY_URL is required}"
SERVER_NAME="agentcore_websearch"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 解析 Gateway MCP endpoint
GATEWAY_URL=$(aws bedrock-agentcore-control get-gateway \
  --gateway-identifier "$GATEWAY_ID" --region "$REGION" \
  --query 'gatewayUrl' --output text)
[ -z "$GATEWAY_URL" ] && { log "ERROR: cannot resolve gateway url"; exit 1; }
log "Gateway MCP endpoint: $GATEWAY_URL"

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
    if s.get('server_name')=='${SERVER_NAME}' or s.get('alias')=='${SERVER_NAME}':
        print(s['server_id']); break
")
if [ -n "$existing_id" ]; then
  log "Deleting existing ${SERVER_NAME} (server_id=${existing_id})"
  curl -sS -X DELETE "${LITELLM_PROXY_URL}/v1/mcp/server/${existing_id}" \
    -H "Authorization: Bearer ${MASTER_KEY}" --max-time 15 > /dev/null
fi

# 创建：auth_type=aws_sigv4，凭证留空 -> LiteLLM 回落 boto3 chain -> ECS task role
log "Creating ${SERVER_NAME} (aws_sigv4, credentials from ECS task role)..."
curl -sS -X POST "${LITELLM_PROXY_URL}/v1/mcp/server" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json
print(json.dumps({
    'server_name': '${SERVER_NAME}',
    'alias': '${SERVER_NAME}',
    'description': 'AWS Bedrock AgentCore managed Web Search Tool (SigV4 via ECS task role)',
    'url': '${GATEWAY_URL}',
    'transport': 'http',
    'auth_type': 'aws_sigv4',
    'aws_region_name': '${REGION}',
    'aws_service_name': 'bedrock-agentcore',
    'allow_all_keys': True,
}))")" --max-time 20 \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
if 'server_id' in d:
    print(f\"  -> server_id={d['server_id']} (status={d.get('status','unknown')})\")
else:
    print(f\"  -> ERROR: {json.dumps(d)[:300]}\"); sys.exit(1)
"

log "Waiting 20s for LiteLLM registry refresh..."
sleep 20

log "Verifying tool web-search-tool___WebSearch is listed..."
FOUND=$(curl -sS "${LITELLM_PROXY_URL}/mcp-rest/tools/list" \
  -H "Authorization: Bearer ${MASTER_KEY}" --max-time 40 \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
names=[t.get('name') for t in d.get('tools',[])]
print('yes' if 'web-search-tool___WebSearch' in names else 'no')
")
if [ "$FOUND" = "yes" ]; then
  log "SUCCESS: web-search-tool___WebSearch available via LiteLLM"
else
  log "WARNING: tool not visible yet; check server health / task role permissions."
  exit 1
fi
