#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="${PROJECT_NAME:-litellm-gw}"
TENANT_NAME="${TENANT_NAME:-default}"
REGION="${AWS_REGION:-us-east-1}"
CFN_DIR="$(cd "$(dirname "$0")/cfn" && pwd)"
CONFIG_DIR="$(cd "$(dirname "$0")/config" && pwd)"

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
  aws cloudformation wait stack-create-complete \
    --stack-name "$stack_name" --region "$REGION" 2>/dev/null \
  || aws cloudformation wait stack-update-complete \
    --stack-name "$stack_name" --region "$REGION" 2>/dev/null
  log "Stack ${stack_name} completed."
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
deploy_stack "${PROJECT_NAME}-data" "${CFN_DIR}/03-data.yaml" \
  "ParameterKey=ProjectName,ParameterValue=${PROJECT_NAME}" \
  "ParameterKey=TenantName,ParameterValue=${TENANT_NAME}" \

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
