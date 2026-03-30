# LiteLLM on AWS — Unified LLM API Gateway

[English](README.md) | [中文](README_CN.md)

Deploy [LiteLLM Proxy](https://github.com/BerriAI/litellm) on AWS as a unified, OpenAI-compatible API gateway for multiple LLM providers (AWS Bedrock, OpenAI, Anthropic, Google Gemini, and more).

> Forked from [zhuangyq008/litellm-on-aws](https://github.com/zhuangyq008/litellm-on-aws) — replaced RDS PostgreSQL with **Aurora Serverless v2** for automatic scaling and cost optimization.

## Features

- **OpenAI-compatible API** — One endpoint for all LLM providers
- **Aurora Serverless v2** — Auto-scaling database (0.5–16 ACU), pay only for what you use
- **Zero-config Bedrock** — AWS Bedrock models via IAM Role, no API keys needed
- **Built-in audit logging** — All calls logged to PostgreSQL SpendLogs at zero extra cost
- **Virtual Keys** — Per-user/team API keys with budget & rate limits
- **One-click deploy** — 5 CloudFormation stacks, fully automated

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           AWS Cloud (VPC)                                   │
│                                                                             │
│   ┌──────────────┐     ┌──────────────┐     ┌────────────────────────────┐ │
│   │  CloudFront   │     │     ALB      │     │     Private Subnets       │ │
│   │  (HTTPS/H2)   │────▶│  (HTTP:80)   │────▶│                          │ │
│   │               │     │  dual-AZ     │     │  ┌────────┐ ┌────────┐  │ │
│   └──────────────┘     └──────────────┘     │  │ ECS #1 │ │ ECS #2 │  │ │
│          ▲                                    │  │Fargate │ │Fargate │  │ │
│          │                                    │  └───┬────┘ └────┬───┘  │ │
│      ┌───┴───┐                                │      │           │       │ │
│      │Client │                                │      ▼           ▼       │ │
│      │curl/  │                                │  ┌───────────────────┐   │ │
│      │SDK    │                                │  │ Aurora Serverless │   │ │
│      └───────┘                                │  │ v2 (PG 16)       │   │ │
│                                               │  │ 0.5─4 ACU        │   │ │
│                                               │  │ Writer + Reader  │   │ │
│                                               │  └───────────────────┘   │ │
│                                               │                          │ │
│                                               │  ┌──────────┐           │ │
│                                               │  │ Valkey   │           │ │
│                                               │  │  (TLS)    │           │ │
│                                               │  └──────────┘           │ │
│                                               └────────────────────────────┘ │
│                                                          │                   │
│                                                          ▼                   │
│                                    ┌──────────────────────────────────┐      │
│                                    │        LLM Providers             │      │
│                                    │  ┌─────────┐  ┌──────────────┐  │      │
│                                    │  │ Bedrock  │  │   OpenAI     │  │      │
│                                    │  │(via IAM) │  │  (API Key)   │  │      │
│                                    │  └─────────┘  └──────────────┘  │      │
│                                    │  ┌─────────┐  ┌──────────────┐  │      │
│                                    │  │Anthropic│  │   Gemini     │  │      │
│                                    │  │(API Key)│  │  (API Key)   │  │      │
│                                    │  └─────────┘  └──────────────┘  │      │
│                                    └──────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────────────────┘
```

| Component | Original Repo | This Fork |
|-----------|--------------|-----------|
| Database | RDS PostgreSQL (db.m7g.large, fixed) | Aurora Serverless v2 (0.5–4 ACU, auto-scaling) |
| Scaling | Manual instance resize | Automatic based on load |
| HA | Multi-AZ standby (idle) | 2 instances (writer + reader) with failover |
| Cost (DB) | ~$200/month always-on | Pay per ACU-hour, ~$43/month at idle |

---

## Quick Start

### 1. Clone and Deploy

```bash
git clone https://github.com/cn-ljh/litellm-on-aws-demo.git
cd litellm-on-aws-demo
chmod +x deploy.sh
./deploy.sh
```

Deployment takes ~20–25 minutes. The script creates 5 CloudFormation stacks in order.

### 2. Get Your Master Key

```bash
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id litellm/<TENANT_NAME>/master-key \
  --region <YOUR_REGION> \
  --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])")
```

> Replace `<TENANT_NAME>` with your tenant name (default: `default`).

### 3. Test It

```bash
# Health check
curl https://<YOUR_CLOUDFRONT_DOMAIN>/health/liveliness
# → "I'm alive!"

# Chat completion (Bedrock — no API key config needed)
curl https://<YOUR_CLOUDFRONT_DOMAIN>/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 200
  }'
```

### 4. Python SDK (OpenAI-compatible)

```python
from openai import OpenAI

client = OpenAI(
    api_key="<MASTER_KEY>",
    base_url="https://<YOUR_CLOUDFRONT_DOMAIN>"
)

response = client.chat.completions.create(
    model="claude-sonnet-4-6",
    messages=[{"role": "user", "content": "Hello!"}],
    max_tokens=200
)
print(response.choices[0].message.content)
```

### 5. Streaming

```bash
curl https://<YOUR_CLOUDFRONT_DOMAIN>/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Write a haiku about cloud computing"}],
    "max_tokens": 500,
    "stream": true
  }'
```

---

## Default Models

| Model Name | Provider | Model ID | Notes |
|-----------|----------|----------|-------|
| `claude-opus-4-6` | AWS Bedrock | `us.anthropic.claude-opus-4-6-v1` | Most capable |
| `claude-sonnet-4-6` | AWS Bedrock | `us.anthropic.claude-sonnet-4-6` | **Best value** |
| `claude-haiku-4-5` | AWS Bedrock | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Fastest & cheapest |
| `gpt-4o` | OpenAI | `openai/gpt-4o` | Requires API key |
| `gpt-4o-mini` | OpenAI | `openai/gpt-4o-mini` | Requires API key |
| `gpt-4.1` | OpenAI | `openai/gpt-4.1` | Requires API key |
| `claude-sonnet-4-20250514` | Anthropic API | `anthropic/claude-sonnet-4-20250514` | Requires API key |
| `claude-haiku-4-5-20251001` | Anthropic API | `anthropic/claude-haiku-4-5-20251001` | Requires API key |
| `gemini-2.0-flash` | Google | `gemini/gemini-2.0-flash` | Requires API key |
| `gemini-2.5-pro` | Google | `gemini/gemini-2.5-pro-preview-05-06` | Requires API key |

Bedrock models use the ECS Task Role for IAM authentication — no API keys needed. Other providers require keys in Secrets Manager.

Edit `config/litellm-config.yaml` to customize models before or after deployment.

---

## Deployment Guide

### Prerequisites

#### AWS Account & Permissions

| Requirement | Details |
|-------------|---------|
| **AWS Account** | Active AWS account |
| **IAM Permissions** | **AdministratorAccess** (or equivalent) for the deploying user/role |
| | Services used: VPC, EC2, ECS, RDS, ElastiCache, S3, CloudFront, Secrets Manager, IAM, CloudWatch, Bedrock, ELB |
| **Service Quotas** | Ensure sufficient quotas for VPC, EIP, NAT Gateway in target region |

#### Tools

| Tool | Min Version | Install |
|------|------------|---------|
| **AWS CLI** | v2.x | [Install Guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| **Python** | 3.8+ | For JSON parsing in scripts |
| **bash** | 4.0+ | Deployment script |

```bash
# Verify AWS CLI is configured
aws sts get-caller-identity
aws configure get region
```

#### Bedrock Model Access (Important)

Bedrock models are **not enabled by default**. You must request access before deployment:

1. Go to [Bedrock Model Access](https://console.aws.amazon.com/bedrock/home#/modelaccess) in your target region
2. Click **Manage model access** → enable:
   - ✅ Anthropic Claude Opus 4.6
   - ✅ Anthropic Claude Sonnet 4.6
   - ✅ Anthropic Claude Haiku 4.5
3. Wait for **Access granted** status (usually a few minutes)

> ⚠️ **Skipping this step will cause 403 errors for all Bedrock model calls.**

#### Third-party API Keys (Optional)

Required only if using non-Bedrock providers:

| Provider | Get Key |
|----------|---------|
| OpenAI | https://platform.openai.com/api-keys |
| Anthropic | https://console.anthropic.com/settings/keys |
| Google Gemini | https://aistudio.google.com/apikey |

### Parameters

| Variable | Default | Description |
|----------|---------|-------------|
| `PROJECT_NAME` | `litellm-gw` | Resource naming prefix |
| `TENANT_NAME` | `default` | Secrets Manager namespace |
| `AWS_REGION` | `us-east-1` | Target region |
| `LITELLM_VERSION` | *(auto-detect)* | Pin a specific version, e.g. `v1.82.3-stable.patch.2` |
| `MinACU` | `0.5` | Aurora minimum capacity (ACU) |
| `MaxACU` | `4` | Aurora maximum capacity (ACU) |

```bash
# Deploy with custom parameters
PROJECT_NAME=my-llm-gw TENANT_NAME=myteam AWS_REGION=us-west-2 ./deploy.sh
```

> **Tip**: For dev/test use `MinACU=0.5 / MaxACU=2`. For production consider `MinACU=1 / MaxACU=16`.

### Deployment Stages

| Stage | Time | Resources |
|-------|------|-----------|
| 1. VPC | ~2 min | VPC, subnets, IGW, NAT GW |
| 2. Secrets | ~1 min | Secrets Manager |
| 3. Data | ~10-15 min | Aurora Serverless v2, Valkey, S3 |
| 4. ECS | ~3-5 min | ECS Fargate, ALB, IAM, CloudWatch |
| 5. CloudFront | ~3-5 min | CloudFront (HTTPS) |

### Configure Provider API Keys (Optional)

Skip this if using only Bedrock models.

```bash
# OpenAI
aws secretsmanager update-secret \
  --secret-id litellm/<TENANT_NAME>/openai \
  --secret-string '{"api_key":"sk-proj-xxxxxxxxx"}' \
  --region <YOUR_REGION>

# Anthropic
aws secretsmanager update-secret \
  --secret-id litellm/<TENANT_NAME>/anthropic \
  --secret-string '{"api_key":"sk-ant-xxxxxxxxx"}' \
  --region <YOUR_REGION>

# Google Gemini
aws secretsmanager update-secret \
  --secret-id litellm/<TENANT_NAME>/gemini \
  --secret-string '{"api_key":"AIzaSyxxxxxxxxx"}' \
  --region <YOUR_REGION>

# Restart to pick up new secrets
aws ecs update-service \
  --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-service \
  --force-new-deployment \
  --region <YOUR_REGION>
```

---

## Use with Claude Code

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) can connect to your LiteLLM gateway as a custom backend. Two configuration methods:

### Method 1: Environment Variables

```bash
export ANTHROPIC_AUTH_TOKEN="sk-xxx"                          # Your LiteLLM Virtual Key
export ANTHROPIC_BASE_URL="https://<YOUR_CLOUDFRONT_DOMAIN>"  # Your gateway endpoint
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-6"
```

> Add to `~/.bashrc` or `~/.zshrc` to persist across sessions.

### Method 2: Settings File (`~/.claude/settings.json`)

```json
{
  "permissions": {
    "allow": []
  },
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "sk-xxx",
    "ANTHROPIC_BASE_URL": "https://<YOUR_CLOUDFRONT_DOMAIN>",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-sonnet-4-6",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-haiku-4-5",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-6"
  }
}
```

This routes all Claude Code requests through your LiteLLM gateway, using Bedrock as the backend — no Anthropic API key needed.

---

## User & Key Management

### Create a Virtual Key

```bash
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "team-backend",
    "duration": "30d",
    "max_budget": 100.0
  }' | python3 -m json.tool
```

The returned `key` (format `sk-xxx`) is the user's API key.

### Key with Model Restrictions

```bash
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "limited-key",
    "models": ["claude-haiku-4-5", "claude-sonnet-4-6"],
    "max_budget": 10.0,
    "duration": "7d",
    "tpm_limit": 100000,
    "rpm_limit": 60
  }' | python3 -m json.tool
```

### Team Management

```bash
# Create team
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/team/new \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "platform-team",
    "max_budget": 500.0,
    "models": ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
  }' | python3 -m json.tool

# Create key for team member (use team_id from above response)
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "member-key",
    "team_id": "<TEAM_ID>",
    "max_budget": 50.0
  }' | python3 -m json.tool
```

### Key Management API

```bash
# List keys
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/list -H "Authorization: Bearer $MASTER_KEY"

# Key info
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/info -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" -d '{"key": "sk-xxx"}'

# Update key
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/update -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" -d '{"key": "sk-xxx", "max_budget": 200.0}'

# Delete key
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/delete -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" -d '{"keys": ["sk-xxx"]}'
```

> **⚠️ Note**: When creating users via the LiteLLM UI, the default `models: ["no-default-models"]` blocks all model access. You must explicitly set the models list for each new user.

---

## Operations

### Update Model Configuration

```bash
# 1. Edit config
vim config/litellm-config.yaml

# 2. Upload to S3
aws s3 cp config/litellm-config.yaml \
  s3://<PROJECT_NAME>-config-<ACCOUNT_ID>/litellm-config.yaml \
  --region <YOUR_REGION>

# 3. Rolling restart (zero downtime)
aws ecs update-service \
  --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-service \
  --force-new-deployment \
  --region <YOUR_REGION>
```

### Audit Logs (SpendLogs)

All API calls are automatically logged to PostgreSQL `LiteLLM_SpendLogs` at zero extra cost.

```bash
# Spend summary
curl -s "https://<YOUR_CLOUDFRONT_DOMAIN>/spend/logs?start_date=$(date +%Y-%m-%d)&end_date=$(date -d '+1 day' +%Y-%m-%d)" \
  -H "Authorization: Bearer $MASTER_KEY" | python3 -m json.tool

# Global spend
curl -s "https://<YOUR_CLOUDFRONT_DOMAIN>/global/spend/logs?start_date=$(date +%Y-%m-%d)&end_date=$(date -d '+1 day' +%Y-%m-%d)" \
  -H "Authorization: Bearer $MASTER_KEY" | python3 -m json.tool
```

### Application Logs

```bash
aws logs tail /ecs/<PROJECT_NAME> --follow --region <YOUR_REGION>
```

### Scaling

```bash
# ECS replicas
aws ecs update-service --cluster <PROJECT_NAME>-cluster --service <PROJECT_NAME>-service \
  --desired-count 4 --region <YOUR_REGION>

# Aurora ACU range
aws rds modify-db-cluster --db-cluster-identifier <PROJECT_NAME>-aurora-cluster \
  --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=16 \
  --apply-immediately --region <YOUR_REGION>
```

### Update Bedrock Models

```bash
# List available inference profiles
aws bedrock list-inference-profiles --region <YOUR_REGION> --type SYSTEM_DEFINED \
  --query "inferenceProfileSummaries[?contains(inferenceProfileName,'Claude')].{Name:inferenceProfileName,ID:inferenceProfileId}" \
  --output table
```

> Bedrock model IDs must use cross-region inference profile format (prefix `us.`), not raw model ARNs.

---

## Cleanup

```bash
# 1. Disable Aurora deletion protection
aws rds modify-db-cluster --db-cluster-identifier <PROJECT_NAME>-aurora-cluster \
  --no-deletion-protection --apply-immediately --region <YOUR_REGION>

# 2. Empty S3 bucket
aws s3 rm s3://<PROJECT_NAME>-config-<ACCOUNT_ID> --recursive --region <YOUR_REGION>

# 3. Delete stacks in reverse order
for stack in <PROJECT_NAME>-cloudfront <PROJECT_NAME>-ecs <PROJECT_NAME>-data <PROJECT_NAME>-secrets <PROJECT_NAME>-vpc; do
  aws cloudformation delete-stack --stack-name $stack --region <YOUR_REGION>
  aws cloudformation wait stack-delete-complete --stack-name $stack --region <YOUR_REGION>
  echo "Deleted: $stack"
done
```

---

## Cost Estimate (Monthly)

| Component | Estimate (USD) | Notes |
|-----------|---------------|-------|
| Aurora Serverless v2 | $30–$150 | Idle ~$43 (0.5 ACU); moderate ~$172 (2 ACU) |
| ECS Fargate (2 replicas) | ~$75 | 1 vCPU / 4GB × 2 |
| ElastiCache Valkey | ~$6 | Serverless (100MB min) |
| NAT Gateway | ~$35 | $0.045/hr + data |
| CloudFront + misc | ~$10 | Per request |
| **Total (infra)** | **$170–$290** | Excludes LLM API costs |

> Compared to fixed RDS (~$200/month DB alone), Aurora Serverless v2 saves ~**70%** at low utilization.

---

## CloudFormation Stacks

| Stack | Resources |
|-------|-----------|
| `*-vpc` | VPC, 2 public + 2 private subnets, IGW, NAT GW |
| `*-secrets` | Secrets Manager (master key, provider API keys) |
| `*-data` | Aurora Serverless v2, ElastiCache Valkey, S3 config |
| `*-ecs` | ECS Fargate, ALB, Task Definition, IAM, CloudWatch |
| `*-cloudfront` | CloudFront distribution (HTTPS, HTTP/2+3) |

## Project Structure

```
litellm-on-aws/
├── cfn/
│   ├── 01-vpc.yaml              # Network
│   ├── 02-secrets.yaml          # Secrets Manager
│   ├── 03-data.yaml             # Aurora, Valkey, S3
│   ├── 04-ecs.yaml              # ECS, ALB, IAM
│   └── 05-cloudfront.yaml       # CloudFront
├── config/
│   └── litellm-config.yaml      # Model routing config
├── deploy.sh                    # Deployment script
└── README.md
```

---

## Troubleshooting


<details>
<summary><b>User key returns "model not allowed" (403) after creating user via UI</b></summary>

When creating users through the LiteLLM Admin UI, there is no model selection field. The default `models` value is set to `["no-default-models"]`, which **blocks access to all models** — even if you later select models when generating a key.

**Fix Option 1: Update user models via API**

```bash
# Set models to empty array = allow all models
curl https://<YOUR_CLOUDFRONT_DOMAIN>/user/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<USER_ID>", "models": []}'

# Or restrict to specific models
curl https://<YOUR_CLOUDFRONT_DOMAIN>/user/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<USER_ID>", "models": ["claude-sonnet-4-6", "claude-haiku-4-5"]}'
```

**Fix Option 2: Use Teams (recommended)**

Create a Team with allowed models, then assign users to that Team. Team-level model permissions override the user default.

```bash
# Create team with model access
curl https://<YOUR_CLOUDFRONT_DOMAIN>/team/new \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias": "dev-team", "models": ["claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-6"]}'
```

> This is a known LiteLLM UI limitation — the user creation form does not expose a model selector.
</details>
<details>
<summary><b>Aurora engine version not available</b></summary>

```bash
aws rds describe-db-engine-versions --engine aurora-postgresql \
  --query "DBEngineVersions[?starts_with(EngineVersion,'16')].EngineVersion" \
  --output text --region <YOUR_REGION>
```
</details>

<details>
<summary><b>ECS tasks crash (OOM)</b></summary>

Increase `TaskMemory` to `4096` in `cfn/04-ecs.yaml`. Keep `--num_workers` ≤ 2.
</details>

<details>
<summary><b>Bedrock "on-demand throughput isn't supported"</b></summary>

Use cross-region inference profile IDs:
```yaml
# Wrong ❌  model: bedrock/anthropic.claude-opus-4-6-v1:0
# Correct ✅ model: bedrock/us.anthropic.claude-opus-4-6-v1
```
</details>

<details>
<summary><b>ALB "Connection refused"</b></summary>

Check if ALB listener exists. Recreate if missing:
```bash
ALB_ARN=$(aws elbv2 describe-load-balancers --names <PROJECT_NAME>-alb --region <YOUR_REGION> --query "LoadBalancers[0].LoadBalancerArn" --output text)
TG_ARN=$(aws elbv2 describe-target-groups --names <PROJECT_NAME>-tg --region <YOUR_REGION> --query "TargetGroups[0].TargetGroupArn" --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 --default-actions Type=forward,TargetGroupArn="$TG_ARN" --region <YOUR_REGION>
```
</details>

<details>
<summary><b>ElastiCache delete fails</b></summary>

Wait for `available` state, then retry:
```bash
aws elasticache describe-serverless-caches --serverless-cache-name <PROJECT_NAME>-redis --region <YOUR_REGION> --query "ServerlessCaches[0].Status"
```
</details>

<details>
<summary><b>CloudFront delete is slow</b></summary>

Normal — global edge node sync takes 5–15 minutes.
</details>

---

## Security Recommendations

| Area | Current | Recommendation |
|------|---------|----------------|
| HTTPS | CloudFront TLS termination | Add custom domain + ACM certificate |
| ALB access | Open | Restrict to CloudFront via managed prefix list or WAF |
| Master Key | Auto-generated | Rotate periodically, limit distribution |
| Database | Multi-AZ + encrypted | Production-ready |
| Valkey | TLS encrypted | Production-ready |
| NAT Gateway | Single AZ | Add second NAT for HA |

<details>
<summary><b>Bedrock returns 403 Forbidden</b></summary>

Model access not enabled. Go to [Bedrock Model Access](https://console.aws.amazon.com/bedrock/home#/modelaccess) and request access.
</details>

<details>
<summary><b>What IAM permissions are required?</b></summary>

The deploying user/role needs permissions for: CloudFormation, VPC, EC2, ECS, RDS, ElastiCache, S3, CloudFront, Secrets Manager, IAM, CloudWatch, Bedrock, ELB.

**Recommended**: Use `AdministratorAccess` for deployment, then tighten permissions for day-to-day operations.
</details>

---

## License

See [LiteLLM License](https://github.com/BerriAI/litellm/blob/main/LICENSE) for the upstream project.
