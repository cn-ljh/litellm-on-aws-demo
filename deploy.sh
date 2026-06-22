#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
TENANT_NAME="${TENANT_NAME:-default}"
REGION="${AWS_REGION:-us-east-1}"
CFN_DIR="$(cd "$(dirname "$0")/cfn" && pwd)"
CONFIG_DIR="$(cd "$(dirname "$0")/config" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Aurora engine version override. Defaults to the template default ("16.6") when
# left empty so existing behaviour is unchanged. Set AURORA_ENGINE_VERSION to
# pin a version available in your target region, e.g.
#   AURORA_ENGINE_VERSION=15.5 ./deploy.sh
AURORA_ENGINE_VERSION="${AURORA_ENGINE_VERSION:-}"

# SearXNG self-hosted web-search MCP (cfn/07). Optional module: builds+pushes the
# two container images, deploys stack 07, and registers the MCP server. Enable
# with DEPLOY_SEARXNG=1 (requires Docker + an authenticated LiteLLM endpoint).
DEPLOY_SEARXNG="${DEPLOY_SEARXNG:-0}"
SEARXNG_IMAGE_TAG="${SEARXNG_IMAGE_TAG:-v1}"

# AgentCore Web Search Tool (cfn/08). Managed, Docker-free web search exposed as
# an MCP tool that LiteLLM calls via SigV4 (ECS task role). Enabled by default
# because it needs no extra infrastructure or API keys; only available in
# us-east-1. Set DEPLOY_AGENTCORE=0 to skip, or SKIP_AGENTCORE_SYNC=1 to deploy
# the stack but register the MCP server later.
DEPLOY_AGENTCORE="${DEPLOY_AGENTCORE:-1}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# Auto-detect latest LiteLLM stable release, or use pinned version
# Note: LiteLLM tag naming changed at 1.84+:
#   - <= 1.83.x: tags are "v1.83.7-stable" → image "ghcr.io/berriai/litellm:main-v1.83.7-stable"
#   - >= 1.84.x: tags are "v1.84.0"        → image "ghcr.io/berriai/litellm:v1.84.0"
# The detection below picks the highest non-prerelease release.
if [ -z "${LITELLM_VERSION:-}" ]; then
  log "Detecting latest LiteLLM stable release..."
  LITELLM_VERSION=$(curl -s "https://api.github.com/repos/BerriAI/litellm/releases"     | python3 -c "import sys,json;rs=json.load(sys.stdin);print(next(r['tag_name'] for r in rs if not r['prerelease']))" 2>/dev/null     || echo "v1.85.2")
  log "Using LiteLLM ${LITELLM_VERSION}"
fi
# Image tag derivation: 1.84+ uses bare tag, older uses main- prefix with -stable suffix
case "$LITELLM_VERSION" in
  *-stable*) LITELLM_IMAGE="ghcr.io/berriai/litellm:main-${LITELLM_VERSION}" ;;
  *)         LITELLM_IMAGE="ghcr.io/berriai/litellm:${LITELLM_VERSION}" ;;
esac
log "Using image: ${LITELLM_IMAGE}"


wait_stack() {
  local stack_name="$1"
  log "Waiting for stack ${stack_name} to complete..."
  # Try create-complete first, then update-complete. If both waiters fail the
  # stack is in a failed/rollback state - surface the actual status + the last
  # failure reason instead of dying silently on set -e.
  if aws cloudformation wait stack-create-complete \
       --stack-name "$stack_name" --region "$REGION" 2>/dev/null \
     || aws cloudformation wait stack-update-complete \
       --stack-name "$stack_name" --region "$REGION" 2>/dev/null; then
    log "Stack ${stack_name} completed."
    return 0
  fi

  local status
  status=$(aws cloudformation describe-stacks \
    --stack-name "$stack_name" --region "$REGION" \
    --query "Stacks[0].StackStatus" --output text 2>/dev/null || echo "UNKNOWN")
  log "ERROR: stack ${stack_name} did not reach a COMPLETE state (status: ${status})."
  log "Most recent failure events:"
  aws cloudformation describe-stack-events \
    --stack-name "$stack_name" --region "$REGION" \
    --query "StackEvents[?contains(ResourceStatus, 'FAILED')].[LogicalResourceId,ResourceStatus,ResourceStatusReason]" \
    --output text 2>/dev/null | head -10 >&2 || true
  return 1
}

deploy_stack() {
  local stack_name="$1"
  local template_file="$2"
  shift 2
  local params=("$@")

  log "Deploying stack: ${stack_name}"
  if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$REGION" &>/dev/null; then
    local update_err
    if ! update_err=$(aws cloudformation update-stack \
      --stack-name "$stack_name" \
      --template-body "file://${template_file}" \
      --parameters "${params[@]}" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$REGION" 2>&1); then
        # The only benign failure is "no changes to apply"; anything else is a real error.
        if echo "$update_err" | grep -q "No updates are to be performed"; then
          log "No updates needed for ${stack_name}, skipping."
          return 0
        fi
        log "ERROR: update-stack failed for ${stack_name}:"
        echo "$update_err" >&2
        return 1
      fi
  else
    aws cloudformation create-stack \
      --stack-name "$stack_name" \
      --template-body "file://${template_file}" \
      --parameters "${params[@]}" \
      --capabilities CAPABILITY_NAMED_IAM \
      --region "$REGION"
  fi
  wait_stack "$stack_name"
}

# ========== Step 1: VPC ==========
deploy_stack "${PROJECT_NAME}-vpc" "${CFN_DIR}/01-vpc.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

# ========== Step 2: Secrets ==========
deploy_stack "${PROJECT_NAME}-secrets" "${CFN_DIR}/02-secrets.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}" \

# ========== Step 3: Data (RDS + Redis + S3) ==========
data_params=(
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}"
)
if [ -n "$AURORA_ENGINE_VERSION" ]; then
  log "Overriding Aurora engine version: ${AURORA_ENGINE_VERSION}"
  data_params+=("ParameterKey=AuroraEngineVersion,ParameterValue=${AURORA_ENGINE_VERSION}")
fi
deploy_stack "${PROJECT_NAME}-data" "${CFN_DIR}/03-data.yaml" "${data_params[@]}"

# ========== Step 4: Upload LiteLLM Config to S3 ==========
CONFIG_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-data" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ConfigBucketName'].OutputValue" \
  --output text)

log "Uploading litellm-config.yaml to s3://${CONFIG_BUCKET}/"
aws s3 cp "${CONFIG_DIR}/litellm-config.yaml" "s3://${CONFIG_BUCKET}/litellm-config.yaml" --region "$REGION"

log "Uploading custom callback bedrock_ctx_stripper.py to s3://${CONFIG_BUCKET}/"
aws s3 cp "${CONFIG_DIR}/callbacks/bedrock_ctx_stripper.py" "s3://${CONFIG_BUCKET}/bedrock_ctx_stripper.py" --region "$REGION"

# ========== Step 5: ECS + ALB ==========
deploy_stack "${PROJECT_NAME}-ecs" "${CFN_DIR}/04-ecs.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}" \
  "ParameterKey=LiteLLMImage,ParameterValue=${LITELLM_IMAGE}"

# ========== Step 6: CloudFront ==========
deploy_stack "${PROJECT_NAME}-cloudfront" "${CFN_DIR}/05-cloudfront.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

# ========== Step 7: SearXNG MCP web-search (optional) ==========
# Builds + pushes the two ARM64 container images to ECR, deploys cfn/07, and
# registers the MCP server in LiteLLM. Gated behind DEPLOY_SEARXNG=1 because it
# requires Docker. Defaults off so the core gateway deploy stays Docker-free.
if [ "$DEPLOY_SEARXNG" = "1" ]; then
  log "========================================="
  log " Step 7: SearXNG MCP web-search module"
  log "========================================="

  ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
  ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
  SEARXNG_REPO="${PROJECT_NAME}/searxng"
  MCP_REPO="${PROJECT_NAME}/searxng-mcp"
  SEARXNG_IMAGE="${ECR_BASE}/${SEARXNG_REPO}:${SEARXNG_IMAGE_TAG}"
  MCP_IMAGE="${ECR_BASE}/${MCP_REPO}:${SEARXNG_IMAGE_TAG}"

  log "Ensuring ECR repositories exist..."
  aws ecr describe-repositories --repository-names "$SEARXNG_REPO" --region "$REGION" &>/dev/null \
    || aws ecr create-repository --repository-name "$SEARXNG_REPO" --region "$REGION" >/dev/null
  aws ecr describe-repositories --repository-names "$MCP_REPO" --region "$REGION" &>/dev/null \
    || aws ecr create-repository --repository-name "$MCP_REPO" --region "$REGION" >/dev/null

  log "Logging in to ECR (${ECR_BASE})..."
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$ECR_BASE"

  # --- buildx + cross-arch prerequisites ---
  # The Fargate tasks run ARM64 (see cfn/07 RuntimePlatform). To build+push ARM64
  # images reliably from ANY host we need:
  #   1) a docker-container buildx builder (the default "docker" driver cannot --push)
  #   2) QEMU/binfmt emulation when the build host is not already arm64 (the MCP
  #      image runs `pip install`, which must execute under arm64).
  HOST_ARCH=$(uname -m)
  if [ "$HOST_ARCH" != "aarch64" ] && [ "$HOST_ARCH" != "arm64" ]; then
    log "Build host is ${HOST_ARCH} (not arm64); installing QEMU/binfmt for cross-build..."
    docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null 2>&1 \
      || log "WARN: binfmt install failed; ARM64 emulation may be unavailable."
  fi
  # Ensure a docker-container builder exists and is selected (idempotent).
  BUILDER_NAME="${PROJECT_NAME}-builder"
  if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
    log "Creating buildx builder ${BUILDER_NAME} (docker-container driver)..."
    docker buildx create --name "$BUILDER_NAME" --driver docker-container --use --bootstrap >/dev/null
  else
    docker buildx use "$BUILDER_NAME"
  fi

  log "Building + pushing SearXNG image: ${SEARXNG_IMAGE}"
  docker buildx build --platform linux/arm64 -t "$SEARXNG_IMAGE" \
    "${SCRIPT_DIR}/searxng-mcp/searxng/" --push
  log "Building + pushing MCP server image: ${MCP_IMAGE}"
  docker buildx build --platform linux/arm64 -t "$MCP_IMAGE" \
    "${SCRIPT_DIR}/searxng-mcp/server/" --push

  # Pull VpcId + private subnets from the VPC stack outputs.
  SEARXNG_VPC_ID=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-vpc" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='VpcId'].OutputValue" --output text)
  PRIV_SUBNET_1=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-vpc" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet1Id'].OutputValue" --output text)
  PRIV_SUBNET_2=$(aws cloudformation describe-stacks \
    --stack-name "${PROJECT_NAME}-vpc" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnet2Id'].OutputValue" --output text)

  # Fail fast on empty lookups: describe-stacks returns "" + exit 0 when an output
  # key is missing, which would otherwise produce a malformed PrivateSubnetIds
  # (e.g. ",subnet-xxx") that only surfaces at CFN validation time.
  for _pair in "VPC:${SEARXNG_VPC_ID}" "PrivateSubnet1:${PRIV_SUBNET_1}" "PrivateSubnet2:${PRIV_SUBNET_2}"; do
    if [ -z "${_pair#*:}" ]; then
      log "ERROR: could not resolve ${_pair%%:*} from stack ${PROJECT_NAME}-vpc outputs."
      log "       Ensure the VPC stack deployed successfully before DEPLOY_SEARXNG=1."
      exit 1
    fi
  done

  # Cloud Map namespace conflict pre-check. cfn/07 CREATEs the private DNS
  # namespace "${PROJECT_NAME}.internal". If a same-named namespace already
  # exists but is NOT managed by this stack (e.g. leftover from a prior manual
  # run), the create would fail mid-deploy with an opaque error. Detect it now
  # and give an actionable message. (Re-running an existing stack is fine - that
  # is an UPDATE and owns its namespace.)
  if ! aws cloudformation describe-stacks --stack-name "${PROJECT_NAME}-searxng-mcp" --region "$REGION" &>/dev/null; then
    NS_DNS="${PROJECT_NAME}.internal"
    # Distinguish "no match" from "call failed": on an API error (perms/throttle)
    # we surface it instead of silently degrading to no-check.
    if ! NS_LIST=$(aws servicediscovery list-namespaces --region "$REGION" \
         --query "Namespaces[?Name=='${NS_DNS}'].Id" --output text 2>&1); then
      log "ERROR: servicediscovery list-namespaces failed (cannot run namespace conflict pre-check):"
      echo "$NS_LIST" >&2
      exit 1
    fi
    if [ -n "$NS_LIST" ] && [ "$NS_LIST" != "None" ]; then
      log "ERROR: Cloud Map namespace '${NS_DNS}' already exists (${NS_LIST}) but is not"
      log "       managed by stack ${PROJECT_NAME}-searxng-mcp. Delete the stray namespace"
      log "       or set a different PROJECT_NAME, then re-run with DEPLOY_SEARXNG=1."
      exit 1
    fi
  fi

  deploy_stack "${PROJECT_NAME}-searxng-mcp" "${CFN_DIR}/07-searxng-mcp.yaml" \
    "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
    "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}" \
    "ParameterKey=VpcId,ParameterValue=${SEARXNG_VPC_ID}" \
    "ParameterKey=PrivateSubnetIds,ParameterValue=\"${PRIV_SUBNET_1},${PRIV_SUBNET_2}\"" \
    "ParameterKey=SearxngImage,ParameterValue=${SEARXNG_IMAGE}" \
    "ParameterKey=McpImage,ParameterValue=${MCP_IMAGE}"

  log "SearXNG MCP stack deployed. Registering MCP server in LiteLLM..."
  # Register against CloudFront endpoint (auth via master-key looked up by the
  # sync script). Skip with SKIP_SEARXNG_SYNC=1 if you prefer to run it later.
  if [ "${SKIP_SEARXNG_SYNC:-0}" = "1" ]; then
    log "SKIP_SEARXNG_SYNC=1 set; run scripts/sync-searxng-mcp.sh manually later."
  else
    SEARXNG_SYNC_URL="${LITELLM_PROXY_URL:-}"
    if [ -z "$SEARXNG_SYNC_URL" ]; then
      CF_DOMAIN_FOR_SYNC=$(aws cloudformation describe-stacks \
        --stack-name "${PROJECT_NAME}-cloudfront" --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomainName'].OutputValue" --output text)
      SEARXNG_SYNC_URL="https://${CF_DOMAIN_FOR_SYNC}"
    fi
    PROJECT_NAME="$PROJECT_NAME" TENANT_NAME="$TENANT_NAME" AWS_REGION="$REGION" \
      LITELLM_PROXY_URL="$SEARXNG_SYNC_URL" "${SCRIPT_DIR}/scripts/sync-searxng-mcp.sh" \
      || log "WARN: sync-searxng-mcp.sh failed; re-run it once LiteLLM is healthy."
  fi
fi

# ========== Step 8: AgentCore Web Search Tool (default on) ==========
# Managed, MCP-compliant web search on Amazon Bedrock AgentCore. Deploys cfn/08
# (Gateway + web-search connector target + Gateway service role + grants the
# LiteLLM ECS task role InvokeGateway) and registers it in LiteLLM as the
# "agentcore_websearch" MCP server (auth_type aws_sigv4, credentials from the
# task role). Docker-free, no API keys. us-east-1 only. Disable with
# DEPLOY_AGENTCORE=0.
if [ "$DEPLOY_AGENTCORE" = "1" ]; then
  log "========================================="
  log " Step 8: AgentCore Web Search Tool"
  log "========================================="
  if [ "$REGION" != "us-east-1" ]; then
    log "WARN: AgentCore Web Search Tool is only available in us-east-1 (region is ${REGION}). Skipping."
  else
    deploy_stack "${PROJECT_NAME}-agentcore-websearch" "${CFN_DIR}/08-agentcore-websearch.yaml" \
      "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}"

    AGENTCORE_GW_ID=$(aws cloudformation describe-stacks \
      --stack-name "${PROJECT_NAME}-agentcore-websearch" --region "$REGION" \
      --query "Stacks[0].Outputs[?OutputKey=='GatewayId'].OutputValue" --output text)
    if [ -z "$AGENTCORE_GW_ID" ] || [ "$AGENTCORE_GW_ID" = "None" ]; then
      log "ERROR: could not resolve AgentCore Gateway id from stack outputs."
      exit 1
    fi

    log "AgentCore Gateway ${AGENTCORE_GW_ID} deployed. Registering MCP server in LiteLLM..."
    if [ "${SKIP_AGENTCORE_SYNC:-0}" = "1" ]; then
      log "SKIP_AGENTCORE_SYNC=1 set; run scripts/sync-agentcore-websearch.sh manually later."
    else
      AGENTCORE_SYNC_URL="${LITELLM_PROXY_URL:-}"
      if [ -z "$AGENTCORE_SYNC_URL" ]; then
        CF_DOMAIN_FOR_AC=$(aws cloudformation describe-stacks \
          --stack-name "${PROJECT_NAME}-cloudfront" --region "$REGION" \
          --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomainName'].OutputValue" --output text)
        AGENTCORE_SYNC_URL="https://${CF_DOMAIN_FOR_AC}"
      fi
      GATEWAY_ID="$AGENTCORE_GW_ID" PROJECT_NAME="$PROJECT_NAME" TENANT_NAME="$TENANT_NAME" \
        AWS_REGION="$REGION" LITELLM_PROXY_URL="$AGENTCORE_SYNC_URL" \
        "${SCRIPT_DIR}/scripts/sync-agentcore-websearch.sh" \
        || log "WARN: sync-agentcore-websearch.sh failed; re-run it once LiteLLM is healthy."
    fi
  fi
fi

# ========== Output ==========
ALB_DNS=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-ecs" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ALBDnsName'].OutputValue" \
  --output text)

CF_DOMAIN=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-cloudfront" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomainName'].OutputValue" \
  --output text)

CF_DIST_ID=$(aws cloudformation describe-stacks \
  --stack-name "${PROJECT_NAME}-cloudfront" \
  --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionId'].OutputValue" \
  --output text)

echo ""
log "========================================="
log " Deployment Complete!"
log " LiteLLM Gateway (ALB):        http://${ALB_DNS}"
log " LiteLLM Gateway (CloudFront): https://${CF_DOMAIN}"
log " CloudFront Distribution ID:   ${CF_DIST_ID}"
log "========================================="
echo ""
log "NEXT STEPS:"
log "  1. Update API keys in Secrets Manager:"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/openai --secret-string '{\"api_key\":\"sk-xxx\"}'"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/anthropic --secret-string '{\"api_key\":\"sk-ant-xxx\"}'"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/gemini --secret-string '{\"api_key\":\"AIxxx\"}'"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/tavily --secret-string '{\"api_key\":\"tvly-xxx\"}'      # MCP: Tavily search"
log "     aws secretsmanager update-secret --secret-id litellm/${TENANT_NAME}/exa --secret-string '{\"api_key\":\"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx\"}'  # MCP: Exa search"
log "  2. Force new ECS deployment to pick up secrets:"
log "     aws ecs update-service --cluster ${PROJECT_NAME}-cluster --service ${PROJECT_NAME}-service --force-new-deployment --region ${REGION}"
log "  3. Verify health (via CloudFront): curl https://${CF_DOMAIN}/health/liveliness"
log "  4. (Optional) Add custom domain: configure CNAME + ACM certificate in CloudFront"
if [ "$DEPLOY_SEARXNG" != "1" ]; then
  log "  5. (Optional) Self-hosted web search: re-run with DEPLOY_SEARXNG=1 ./deploy.sh"
  log "     (builds searxng images, deploys cfn/07, registers searxng-web_search MCP; needs Docker)"
fi
if [ "$DEPLOY_AGENTCORE" = "1" ] && [ "$REGION" = "us-east-1" ]; then
  log "  AgentCore Web Search Tool deployed + registered (MCP tool web-search-tool___WebSearch)."
fi
