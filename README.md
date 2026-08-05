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
- **ECS Auto Scaling** — CPU-based target tracking (2–4 tasks), automatic scale-out/in
- **Graviton (ARM64)** — 20% lower compute cost with AWS Graviton processors
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
| HA | Multi-AZ standby (idle) | 2 instances (writer + reader) with automatic failover. The reader is a warm standby for AZ/instance failure (auto-promoted on failover), not a read-traffic offload — LiteLLM connects to the writer endpoint only. Drop `AuroraInstance2` for a cheaper non-HA setup. |
| Cost (DB) | ~$200/month always-on | Pay per ACU-hour, ~$43/month at idle |

---

## Quick Start

> **⚠️ For AI agents / automated deployment tools:** Before running `deploy.sh`, **confirm the Aurora PostgreSQL engine version with the user.** The template defaults to `16.8` (the PostgreSQL 16 LTS release, standard support through 2029-02), which is proven with LiteLLM's Prisma-managed schema. Do **not** silently jump to PostgreSQL 17.x — LiteLLM has had reports of Prisma first-run table-creation failures on PG17 (see BerriAI/litellm#9400), so any move to 17.x should be an explicit, user-approved decision after validating a fresh Prisma migration. Also verify the chosen version is available in the target region (`aws rds describe-db-engine-versions --engine aurora-postgresql`). Override via the `AURORA_ENGINE_VERSION` env var.

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
| `claude-opus-5` | AWS Bedrock | `us.anthropic.claude-opus-5` | **Most capable** — 1M context, 128K output; adaptive thinking on by default. Rejects `temperature`/`top_p`/`top_k` (must be dropped) |
| `claude-sonnet-4-6` | AWS Bedrock | `us.anthropic.claude-sonnet-4-6` | **Best value** |
| `claude-haiku-4-5` | AWS Bedrock | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | Fastest & cheapest |
| `gpt-5.6-sol` | AWS Bedrock (Mantle) | `bedrock_mantle/openai.gpt-5.6-sol` | OpenAI flagship — reasoning + agentic (coding/security/research). Responses API. us-east-1 / us-east-2 |
| `gpt-5.6-terra` | AWS Bedrock (Mantle) | `bedrock_mantle/openai.gpt-5.6-terra` | Balanced, ~half Sol's cost. + us-west-2 |
| `gpt-5.6-luna` | AWS Bedrock (Mantle) | `bedrock_mantle/openai.gpt-5.6-luna` | Fastest & cheapest, high-volume. + us-west-2 |
| `gpt-4o` | OpenAI | `openai/gpt-4o` | Requires API key |
| `gpt-4o-mini` | OpenAI | `openai/gpt-4o-mini` | Requires API key |
| `gpt-4.1` | OpenAI | `openai/gpt-4.1` | Requires API key |
| `claude-sonnet-4-20250514` | Anthropic API | `anthropic/claude-sonnet-4-20250514` | Requires API key |
| `claude-haiku-4-5-20251001` | Anthropic API | `anthropic/claude-haiku-4-5-20251001` | Requires API key |
| `gemini-2.0-flash` | Google | `gemini/gemini-2.0-flash` | Requires API key |
| `gemini-2.5-pro` | Google | `gemini/gemini-2.5-pro-preview-05-06` | Requires API key |

All AWS Bedrock models (Claude **and** GPT-5.6) authenticate via the ECS Task Role — **no API keys needed**. GPT-5.6 runs on the `bedrock-mantle` endpoint (OpenAI Responses API); the Task Role includes a `BedrockMantleAccess` policy for it (see `cfn/04-ecs.yaml`). Other providers require keys in Secrets Manager.

> **Region note:** Bedrock model IDs use the cross-region inference profile prefix (`us.`). The config does **not** hardcode a region — models inherit the deployment region from the injected `AWS_REGION_NAME`. Adjust the profile prefix (`eu.`/`apac.`) if deploying outside the US. GPT-5.6 Sol is only in us-east-1/us-east-2; Terra & Luna add us-west-2.

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
   - ✅ Anthropic Claude Opus 4.8
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
| `AURORA_ENGINE_VERSION` | *(template default `16.8`, PG16 LTS)* | Override Aurora PostgreSQL engine version if `16.8` is unavailable in your region |
| `DEPLOY_AGENTCORE` | `1` *(on)* | Deploy AgentCore Web Search (managed web search, `cfn/08`) and register it in LiteLLM. Docker-free, no API keys, **on by default**. Only effective in `us-east-1` (skipped with a warning elsewhere). Set `0` to skip |
| `SKIP_AGENTCORE_SYNC` | `0` | With `DEPLOY_AGENTCORE=1`, set `1` to deploy `cfn/08` only and register the MCP server later |
| `DEPLOY_SEARXNG` | `0` | Set `1` to also build/push the SearXNG images, deploy `cfn/07`, and register the `searxng-web_search` MCP (requires Docker) |
| `SEARXNG_IMAGE_TAG` | `v1` | Image tag for the SearXNG + MCP server images |
| `SKIP_SEARXNG_SYNC` | `0` | With `DEPLOY_SEARXNG=1`, set `1` to skip the post-deploy MCP registration |

```bash
# Deploy with custom parameters
PROJECT_NAME=my-llm-gw TENANT_NAME=myteam AWS_REGION=us-west-2 ./deploy.sh

# Override Aurora engine version (e.g. region without 16.8)
AURORA_ENGINE_VERSION=15.5 ./deploy.sh

# One-shot deploy including the self-hosted SearXNG web-search MCP module
DEPLOY_SEARXNG=1 ./deploy.sh

# Skip the (default-on) AgentCore Web Search step
DEPLOY_AGENTCORE=0 ./deploy.sh
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
| 6. AgentCore Web Search *(default on, `us-east-1`)* | ~2-3 min | AgentCore Gateway + web-search target + service role + task-role grant + LiteLLM MCP registration |
| 7. SearXNG MCP *(optional, `DEPLOY_SEARXNG=1`)* | ~5-8 min | ECR images, Fargate service, Cloud Map DNS, MCP registration |

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
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-8"
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
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8"
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
    "models": ["claude-haiku-4-5", "claude-sonnet-4-6", "claude-opus-4-8"],
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
    "models": ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
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

**ECS Auto Scaling** is enabled by default with CPU-based target tracking:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `MinCapacity` | 2 | Minimum number of ECS tasks |
| `MaxCapacity` | 4 | Maximum number of ECS tasks |
| `CpuTargetValue` | 70 | Target CPU utilization (%) |

Scale-out cooldown: 60s · Scale-in cooldown: 300s

To adjust Auto Scaling parameters:
```bash
aws cloudformation update-stack --stack-name <PROJECT_NAME>-ecs \
  --template-body file://cfn/04-ecs.yaml \
  --parameters ParameterKey=ProjectName,ParameterValue=<PROJECT_NAME> \
               ParameterKey=TenantName,ParameterValue=default \
               ParameterKey=MinCapacity,ParameterValue=2 \
               ParameterKey=MaxCapacity,ParameterValue=8 \
               ParameterKey=CpuTargetValue,ParameterValue=60 \
  --capabilities CAPABILITY_NAMED_IAM --region <YOUR_REGION>
```

To manually override replica count (temporary, Auto Scaling will adjust):
```bash
aws ecs update-service --cluster <PROJECT_NAME>-cluster --service <PROJECT_NAME>-service \
  --desired-count 4 --region <YOUR_REGION>
```

```bash
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

## Updating Your Environment

After the initial deploy, the two things you'll change most often are the **LiteLLM version** and the **model list**. Both are low-risk when done in the right order. The gateway loads `config/litellm-config.yaml` from S3 at container start, so a config change just needs a rolling restart.

### Upgrade the LiteLLM version

The running version is pinned by the container image tag (CloudFormation parameter `LiteLLMImage`). `deploy.sh` auto-detects the latest stable release, or you can pin one explicitly.

```bash
# 1. See the currently running version (check the ECS task definition image tag)
aws ecs describe-task-definition --task-definition <PROJECT_NAME>-task \
  --query 'taskDefinition.containerDefinitions[0].image' --output text --region <YOUR_REGION>

# 2. Pin a target version and re-run deploy.sh (updates the ECS stack only)
#    Tag naming: 1.84+ uses a bare tag "v1.95.0"; <= 1.83.x used "main-v1.83.7-stable".
#    deploy.sh handles both. Omit LITELLM_VERSION to auto-detect the latest stable.
LITELLM_VERSION=v1.95.0 ./deploy.sh

# 3. Verify after rollout (ECS rolling replace is zero-downtime: minHealthy=100%, max=200%)
curl -s https://<YOUR_ENDPOINT>/health/readiness   # -> {"status":"healthy","db":"connected"}
```

> **Check model-registry support before upgrading _to use a new model_.** A model only works once LiteLLM's price/context map knows it. Example: OpenAI GPT-5.6 landed in **v1.93.0** (absent in 1.92.0). Confirm with:
> ```bash
> curl -s "https://raw.githubusercontent.com/BerriAI/litellm/<TAG>/model_prices_and_context_window.json" \
>   | python3 -c "import sys,json;d=json.load(sys.stdin);print([k for k in d if 'gpt-5.6' in k])"
> ```

> **Prisma migrations are one-way.** A new version may add DB tables/columns on first boot (forward-compatible: adds only, never drops). Rolling the *image* back is fine; the schema stays. Plan accordingly if one Aurora cluster is shared across versions.

> **Keep `--num_workers 1`** on 0.5 vCPU tasks. LiteLLM 1.80+ silently crashes child workers with `>= 2` ([#18457](https://github.com/BerriAI/litellm/issues/18457)).

### Add or change models

Models live in `config/litellm-config.yaml`. Edit, sync to S3, force a rolling restart.

```bash
# 1. Edit config/litellm-config.yaml (add/remove a model_list entry)

# 2. Upload to the config bucket (back up the current one first)
BUCKET=<PROJECT_NAME>-config-<ACCOUNT_ID>
aws s3 cp "s3://$BUCKET/litellm-config.yaml" "s3://$BUCKET/backups/litellm-config.$(date +%Y%m%d-%H%M%S).yaml" --region <YOUR_REGION>
aws s3 cp config/litellm-config.yaml "s3://$BUCKET/litellm-config.yaml" --region <YOUR_REGION>

# 3. Rolling restart so containers reload config from S3
aws ecs update-service --cluster <PROJECT_NAME>-cluster --service <PROJECT_NAME>-service \
  --force-new-deployment --region <YOUR_REGION>
aws ecs wait services-stable --cluster <PROJECT_NAME>-cluster --services <PROJECT_NAME>-service --region <YOUR_REGION>

# 4. Verify the new model is live
curl -s https://<YOUR_ENDPOINT>/v1/models -H "Authorization: Bearer <MASTER_KEY>" \
  | python3 -c "import sys,json;print([m['id'] for m in json.load(sys.stdin)['data']])"
```

**Bedrock model conventions used in this repo:**

- **No hardcoded region.** Bedrock entries omit `aws_region_name`; region is inherited from the `AWS_REGION_NAME` env injected by the ECS task. Use the inference-profile prefix (`us.`/`eu.`/`apac.`) matching your region.
- **Claude** uses `bedrock/us.anthropic.<model>` with IAM via the task role.
- **GPT-5.6** uses `bedrock_mantle/openai.gpt-5.6-<sol|terra|luna>` (OpenAI Responses API on the `bedrock-mantle` endpoint). Auth is SigV4 via the task role — the `BedrockMantleAccess` policy in `cfn/04-ecs.yaml` grants it. No API key needed.
- **GPT-5.x drops sampling params.** Put `temperature`, `top_p`, `top_k` in `additional_drop_params`, or clients sending defaults get `400 ValidationException`.
- New Bedrock models are **not enabled by default** in your account — request access in the Bedrock console for your region first, or calls return `403`.

### Safer upgrades: blue-green (optional)

For a canary before promoting a version to all traffic, run a second ECS service on a separate target group and route to it with a header rule (e.g. `X-Lane: blue`). Bring the new version up on the standby lane, validate it via the header, then flip the ALB default action. Keep the previous task definition to roll back in ~30s by flipping the listener back. (The public template ships a single lane to stay simple; blue-green is an operational pattern you can layer on.)

---

## MCP Gateway (Tavily + Exa + SearXNG + AgentCore Web Search)

LiteLLM Proxy doubles as an **MCP Gateway** that exposes search tools (Tavily, Exa, self-hosted SearXNG, AgentCore Web Search) to all clients via a single endpoint. Clients no longer need their own search API keys.

### Available tools

- `tavily-tavily_search`, `tavily-tavily_extract`, `tavily-tavily_crawl`, `tavily-tavily_map`, `tavily-tavily_research`
- `exa-web_search_exa`, `exa-web_fetch_exa`
- `searxng-web_search` (self-hosted, no API key / no quota)
- `web-search-tool___WebSearch` (AgentCore managed web search, deployed by default; no API key)

### Client usage

OpenAI Responses API:
```json
{
  "type": "mcp",
  "server_label": "litellm",
  "server_url": "litellm_proxy",
  "require_approval": "never"
}
```

Direct MCP protocol (`POST /mcp/` JSON-RPC, `Authorization: Bearer <virtual_key>`).

### Claude Code client integration

Claude Code (CLI ≥ 2.x) can register the LiteLLM MCP Gateway as a remote MCP server, giving it access to all 7 search tools without configuring Tavily/Exa keys locally.

**1. Create a dedicated virtual key on the proxy** (do *not* hand out the master key):

```bash
curl -X POST https://your-domain/key/generate \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "claude-code-mcp",
    "models": ["all-proxy-models"],
    "metadata": {"purpose": "claude-code mcp gateway"}
  }'
# → returns "key": "sk-xxxx..."
```

**2. Register the MCP server in Claude Code** (run on each client machine):

Linux / macOS:
```bash
claude mcp add --transport http --scope user litellm-search \
  https://your-domain/mcp/ \
  --header "Authorization: Bearer sk-xxxx..."
```

Windows PowerShell (note backtick line continuation):
```powershell
claude mcp add --transport http --scope user litellm-search `
  https://your-domain/mcp/ `
  --header "Authorization: Bearer sk-xxxx..."
```

Verify:
```bash
claude mcp list
# litellm-search ✓ Connected (7 tools)
```

**3. Disable Claude Code's built-in `WebSearch` tool** so it stops attempting the unreachable Anthropic search endpoint and falls through to `litellm-search`. Edit `~/.claude/settings.json` (Windows: `C:\Users\<you>\.claude\settings.json`) and add `permissions.deny`:

```json
{
  "permissions": {
    "deny": ["WebSearch", "WebFetch"]
  },
  "env": {
    "ANTHROPIC_AUTH_TOKEN": "sk-xxxx...",
    "ANTHROPIC_BASE_URL": "https://your-domain"
  },
  "model": "claude-opus-4-8"
}
```

Restart Claude Code. From then on it will route every web-search/fetch through `tavily-tavily_search` / `exa-web_search_exa` / `tavily-tavily_extract`, instead of burning ~1s on the dead built-in `WebSearch` per call.

**Revoke a key** (if a client machine is decommissioned):
```bash
curl -X POST https://your-domain/key/delete \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -d '{"keys":["sk-xxxx..."]}'
```

### Setup (one-time)

1. Update Secrets Manager with real keys:
   ```bash
   aws secretsmanager update-secret --secret-id litellm/<TENANT>/tavily \
     --secret-string '{"api_key":"tvly-xxx"}'
   aws secretsmanager update-secret --secret-id litellm/<TENANT>/exa \
     --secret-string '{"api_key":"xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"}'
   ```

2. Run the sync script (idempotent, writes to LiteLLM DB):
   ```bash
   AWS_REGION=us-east-1 LITELLM_PROXY_URL=https://your-domain \
     ./scripts/sync-mcp-servers.sh
   ```

### Why DB-based and not yaml-based?

LiteLLM 1.85.2 has a bug where yaml-loaded `mcp_servers` are not picked up by the auth chain — admin/virtual keys see empty `tools/list` even with `allow_all_keys: true`. Going through the admin REST API (`POST /v1/mcp/server`) writes to `LiteLLM_MCPServerTable` and works correctly. See `scripts/sync-mcp-servers.sh` and the `feat(mcp)` commit history for details.

> ⚠️ Known LiteLLM 1.85.2 issues:
> - `auth_type: bearer_token` does not persist `authentication_token` — use `static_headers: {Authorization: "Bearer <KEY>"}` instead.
> - `GET /v1/mcp/server` echoes `static_headers` API keys in plaintext — keep your master key tightly controlled.

### SearXNG: self-hosted web search (no API key)

`searxng-web_search` is backed by a **self-hosted SearXNG metasearch instance** running as a standalone ECS Fargate service in the same cluster (`searxng-mcp`), so web search keeps working with zero external API cost/quota.

**Architecture** (`cfn/07-searxng-mcp.yaml` + `searxng-mcp/`):

```
LiteLLM tasks ──(Cloud Map private DNS: searxng-mcp.litellm-gw.internal:8000/mcp)──▶
  searxng-mcp task (Fargate, private subnets, no public IP)
    ├── mcp container   : Python FastMCP, streamable-HTTP, stateless (any replica works)
    └── searxng container: searxng/searxng with formats:[html,json], limiter off
        └── localhost:8080 inside the task; queries public engines via NAT
```

- **One task, two containers** — the MCP server calls SearXNG over `localhost:8080`; only port 8000 (MCP) is exposed outside the task.
- **Service discovery**: Cloud Map private DNS namespace `litellm-gw.internal` (A records, TTL 10s). LiteLLM is *not* modified — it just resolves the internal hostname. No ALB involved, traffic never leaves the VPC.
- **Security group** `searxng-mcp` (least privilege, no `0.0.0.0/0` ingress):
  - ingress: tcp/8000 from the LiteLLM task SG only
  - egress: tcp/443 only (search engines via NAT, ECR pull, CloudWatch Logs)
- **No auth on the MCP endpoint by design**: the SG is the auth boundary (only LiteLLM tasks can connect). LiteLLM-side virtual-key auth still applies to clients.
- **Secrets**: `litellm/<TENANT>/searxng-secret` (auto-generated `server.secret_key`); no search API keys needed.

**Deploy / update:**

> **One-shot:** `DEPLOY_SEARXNG=1 ./deploy.sh` does all of the steps below automatically — creates the ECR repos, builds & pushes the ARM64 images, deploys `cfn/07` (resolving VpcId/private subnets from the VPC stack), and registers the MCP server against the CloudFront endpoint. The manual steps below are for standalone/iterative updates.

```bash
# 1. Create the ECR repositories (one-time; skip if they already exist)
aws ecr create-repository --repository-name litellm-gw/searxng --region us-east-1
aws ecr create-repository --repository-name litellm-gw/searxng-mcp --region us-east-1

# 2. Build & push images (ARM64)
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com
docker build -t <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/litellm-gw/searxng:v1 searxng-mcp/searxng/
docker build -t <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/litellm-gw/searxng-mcp:v1 searxng-mcp/server/
docker push <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/litellm-gw/searxng:v1
docker push <ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/litellm-gw/searxng-mcp:v1

# 3. Deploy the stack
#    The LiteLLM task SG is imported automatically from the ECS stack
#    (export "<PROJECT_NAME>-ECSSecurityGroup"), so no SG param is needed.
#    Cluster name and Cloud Map namespace are derived from ProjectName.
aws cloudformation create-stack --stack-name litellm-gw-searxng-mcp \
  --template-body file://cfn/07-searxng-mcp.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters ParameterKey=ProjectName,ParameterValue=litellm-gw \
    ParameterKey=VpcId,ParameterValue=<VPC> \
    "ParameterKey=PrivateSubnetIds,ParameterValue='<SUBNET1>,<SUBNET2>'" \
    ParameterKey=SearxngImage,ParameterValue=<ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/litellm-gw/searxng:v1 \
    ParameterKey=McpImage,ParameterValue=<ACCOUNT>.dkr.ecr.us-east-1.amazonaws.com/litellm-gw/searxng-mcp:v1

# 4. Register to LiteLLM DB (idempotent)
LITELLM_PROXY_URL=https://your-domain ./scripts/sync-searxng-mcp.sh
```

> Note: the SearXNG container reads `/etc/searxng/settings.yml` baked into the image (JSON output format must be explicitly enabled — the stock image only serves HTML). The MCP server runs `stateless_http=true` so LiteLLM's per-request MCP client needs no session affinity.

---

### AgentCore Web Search: managed web search (default on, no API key)

Amazon Bedrock AgentCore went GA on 2026-06-17 with a fully managed, MCP-compliant Web Search tool: Amazon's own continuously-updated index, queries never leave AWS, zero infrastructure, no API keys. The repo wires it in via `cfn/08-agentcore-websearch.yaml` and **`deploy.sh` deploys + registers it by default** (`DEPLOY_AGENTCORE=1`). It coexists with the self-hosted SearXNG MCP; it does not replace it. **`us-east-1` only.**

How it works:
- A **AgentCore Gateway** (`AuthorizerType: AWS_IAM`, MCP) plus a Web Search target (`connectorId: web-search`, tool `WebSearch`).
- The Gateway uses a service role (`InvokeGateway` + `InvokeWebSearch`; the latter scoped to the service-owned ARN `arn:aws:bedrock-agentcore:<region>:aws:tool/web-search.v1`).
- **Inbound auth is IAM — no keys, no Cognito/Keycloak.** `cfn/08` grants the LiteLLM ECS task role `bedrock-agentcore:InvokeGateway` automatically (the task role name is pulled from the ECS stack export `${ProjectName}-ECSTaskRoleName` via `Fn::ImportValue`, so nothing is hand-wired). LiteLLM registers the server with `auth_type=aws_sigv4` and **empty credentials**, so it falls back to the boto3 chain (the task role) and SigV4-signs every MCP request. Requires LiteLLM >= v1.80.18.

Default deploy (nothing to do — runs as Step 6 after CloudFront):
```bash
./deploy.sh            # AgentCore Web Search deployed + registered automatically
DEPLOY_AGENTCORE=0 ./deploy.sh    # skip it
SKIP_AGENTCORE_SYNC=1 ./deploy.sh # deploy cfn/08 but register the MCP server later
```

Manual / standalone registration (stack already exists, or registering later):
```bash
# GATEWAY_ID comes from the cfn/08 output "GatewayId"
GATEWAY_ID=litellm-websearch-gw-xxxxxxxx \
  LITELLM_PROXY_URL=https://<your-cloudfront-domain> \
  PROJECT_NAME=litellm-gw TENANT_NAME=default AWS_REGION=us-east-1 \
  ./scripts/sync-agentcore-websearch.sh
```

Verify (model autonomously calls the tool):
```bash
curl -s -X POST https://<cloudfront-domain>/v1/responses \
  -H "Authorization: Bearer <master_key>" -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","input":"Use web search for a current news item and give a source URL",
       "tools":[{"type":"mcp","server_label":"agentcore_websearch","server_url":"litellm_proxy","require_approval":"never"}]}'
```

The tool appears in LiteLLM as `web-search-tool___WebSearch`, alongside SearXNG's `web_search`, Tavily, and Exa.

---

## Cleanup

```bash
# 1. Disable Aurora deletion protection
aws rds modify-db-cluster --db-cluster-identifier <PROJECT_NAME>-aurora-cluster \
  --no-deletion-protection --apply-immediately --region <YOUR_REGION>

# 2. Empty S3 bucket
aws s3 rm s3://<PROJECT_NAME>-config-<ACCOUNT_ID> --recursive --region <YOUR_REGION>

# 3. Delete stacks in reverse order (optional modules first - cfn/08 attaches a
#    policy to the ECS task role, so it must be removed before the ECS stack)
for stack in <PROJECT_NAME>-agentcore-websearch <PROJECT_NAME>-searxng-mcp <PROJECT_NAME>-cloudfront <PROJECT_NAME>-ecs <PROJECT_NAME>-data <PROJECT_NAME>-secrets <PROJECT_NAME>-vpc; do
  aws cloudformation delete-stack --stack-name $stack --region <YOUR_REGION> 2>/dev/null || true
  aws cloudformation wait stack-delete-complete --stack-name $stack --region <YOUR_REGION> 2>/dev/null || true
  echo "Deleted: $stack"
done
```

---

## Cost Estimate (Monthly)

| Component | Estimate (USD) | Notes |
|-----------|---------------|-------|
| Aurora Serverless v2 | $30–$150 | Idle ~$43 (0.5 ACU); moderate ~$172 (2 ACU) |
| ECS Fargate (2–4 replicas) | ~$50–$100 | 0.5 vCPU / 4GB × 2–4 (Graviton, Auto Scaling) |
| ElastiCache Valkey | ~$6 | Serverless (100MB min) |
| NAT Gateway | ~$35 | $0.045/hr + data |
| CloudFront + misc | ~$10 | Per request |
| **Total (infra)** | **$140–$240** | Excludes LLM API costs |

> Compared to fixed RDS (~$200/month DB alone), Aurora Serverless v2 saves ~**70%** at low utilization.

---

## CloudFormation Stacks

| Stack | Resources |
|-------|-----------|
| `*-vpc` | VPC, 2 public + 2 private subnets, IGW, NAT GW |
| `*-secrets` | Secrets Manager (master key, provider API keys) |
| `*-data` | Aurora Serverless v2, ElastiCache Valkey, S3 config |
| `*-ecs` | ECS Fargate (Graviton/ARM64), ALB, Auto Scaling, Task Definition, IAM, CloudWatch |
| `*-cloudfront` | CloudFront distribution (HTTPS, HTTP/2+3) |

## Project Structure

```
litellm-on-aws/
├── cfn/
│   ├── 01-vpc.yaml              # Network
│   ├── 02-secrets.yaml          # Secrets Manager
│   ├── 03-data.yaml             # Aurora, Valkey, S3
│   ├── 04-ecs.yaml              # ECS, ALB, IAM
│   ├── 05-cloudfront.yaml       # CloudFront
│   ├── 07-searxng-mcp.yaml      # SearXNG MCP web-search service (optional, Docker)
│   └── 08-agentcore-websearch.yaml  # AgentCore managed web search (default on, us-east-1)
├── config/
│   ├── litellm-config.yaml      # Model routing config
│   └── callbacks/
│       └── bedrock_ctx_stripper.py  # Strips context_management for Bedrock
├── searxng-mcp/                 # SearXNG + MCP server container sources
│   ├── searxng/
│   └── server/
├── scripts/
│   ├── sync-mcp-servers.sh      # Register Tavily/Exa MCP servers
│   └── sync-searxng-mcp.sh      # Register SearXNG MCP server
├── deploy.sh                    # Deployment script
├── README.md                    # English
└── README_CN.md                 # 中文
```

---

## Troubleshooting


<details>
<summary><b>Deploy/delete fails on the S3 config bucket with <code>s3:PutEncryptionConfiguration</code> explicit deny (SCP)</b></summary>

If your account is in an AWS Organization whose Service Control Policy denies `s3:PutEncryptionConfiguration`, the `*-data` stack fails to create **and** to delete the `ConfigBucket` (403 explicit deny), because CloudFormation calls `PutBucketEncryption` for the `BucketEncryption` property.

**Fix:** remove the `BucketEncryption` block from `cfn/03-data.yaml` (`ConfigBucket`). S3 buckets are AES256-encrypted by default since Jan 2023, so the bucket stays encrypted. If a stack is already stuck in `DELETE_FAILED`, empty all object **versions** first (`aws s3api delete-object --version-id ...` for every version and delete marker, since versioning is enabled), then re-run the stack delete.

</details>

<details>
<summary><b><code>DEPLOY_SEARXNG=1</code> build fails: SearXNG base image "not found"</b></summary>

Upstream `searxng/searxng` only publishes rolling date-stamped tags (e.g. `2026.6.22-<sha>`) and prunes old ones, so a tag pinned in the Dockerfile can disappear from Docker Hub and break the build.

**Fix:** update `FROM searxng/searxng:<tag>` in `searxng-mcp/searxng/Dockerfile` to a current tag (confirm it includes `linux/arm64` via `docker buildx imagetools inspect searxng/searxng:<tag>`), or pin to an immutable digest `searxng/searxng@sha256:<digest>`.

</details>

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
  -d '{"team_alias": "dev-team", "models": ["claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-8"]}'
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

<details>
<summary><b>Intermittent 504 Gateway Timeout on long POST /v1/messages (Claude long-context)</b></summary>

**Symptom**: Clients using the Anthropic Messages API (`POST /v1/messages`) against `https://<YOUR_CLOUDFRONT_DOMAIN>` occasionally get 504 errors after exactly ~60 seconds, while the ECS/LiteLLM backend logs the same request as `200 OK`. CloudFront access logs show `x-edge-detailed-result-type = OriginCommError` and `time-taken ≈ 60.1s`.

**Root cause**: Both the ALB (default `idle_timeout = 60s`) and the CloudFront origin (default `OriginReadTimeout = 60s`) cut the upstream connection before the LLM finishes. Claude long-context / non-streaming calls commonly exceed 60s TTFB, especially for Opus / extended-thinking requests.

**Fix (already in this repo in this release)**:
- `cfn/04-ecs.yaml` sets ALB `idle_timeout.timeout_seconds = 4000` (ALB max).
- `cfn/05-cloudfront.yaml` sets `OriginReadTimeout = 120` (CloudFront quota max, adjustable) and `OriginKeepaliveTimeout = 60`.

**One-shot patch for an already-deployed stack** (no redeploy needed):

```bash
# Raise ALB idle timeout
aws elbv2 modify-load-balancer-attributes --region <YOUR_REGION> \
  --load-balancer-arn <ALB_ARN> \
  --attributes Key=idle_timeout.timeout_seconds,Value=4000

# Raise CloudFront origin timeouts (update the distribution config)
aws cloudfront get-distribution-config --id <DIST_ID> > /tmp/cf.json
ETAG=$(jq -r .ETag /tmp/cf.json)
jq '.DistributionConfig
    | .Origins.Items[0].CustomOriginConfig.OriginReadTimeout = 120
    | .Origins.Items[0].CustomOriginConfig.OriginKeepaliveTimeout = 60' \
  /tmp/cf.json > /tmp/cf-new.json
aws cloudfront update-distribution --id <DIST_ID> --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-new.json
```

**Recommendation**: Even after raising the timeouts, prefer streaming (`"stream": true`) from your client. Streaming sends chunks continuously, so the ALB idle timer never fires and p99 latency is much better.
</details>

<details>
<summary><b>400 <code>context_management: Extra inputs are not permitted</code> from Claude Code / other new Anthropic clients</b></summary>

**Symptom**: Calls to `POST /v1/messages` with a `context_management` field (auto-injected by Claude Code 2.1.116+ and some newer Anthropic SDK versions for context compaction) fail with:

```
API Error: 400 {"error":{"message":"{\"message\":\"context_management: Extra inputs are not permitted\"}.
Received Model Group=claude-sonnet-4-6 ..."}}
```

**Root cause**: AWS Bedrock's Anthropic Invoke endpoint does not accept the `context_management` parameter yet (as of 2026-04). LiteLLM forwards the field unchanged through the `/v1/messages` route (Anthropic passthrough), and Bedrock rejects it with the strict Pydantic message above. Note that `additional_drop_params: [context_management]` set under `litellm_settings` / `litellm_params` only drops the param on the **OpenAI-format** (`/v1/chat/completions`) path — it does NOT take effect on `/v1/messages`.

**Fix (already in this repo)**: A custom `CustomLogger` pre-call hook strips `context_management` from request data before it reaches Bedrock. Lives in [`config/callbacks/bedrock_ctx_stripper.py`](config/callbacks/bedrock_ctx_stripper.py) and is registered in `config/litellm-config.yaml`:

```yaml
litellm_settings:
  callbacks: ["bedrock_ctx_stripper.bedrock_ctx_stripper_instance"]
```

The callback file is uploaded to S3 alongside `litellm-config.yaml` by `deploy.sh`, and the ECS task command pulls both files at container boot (see `cfn/04-ecs.yaml`), exporting `PYTHONPATH=/app:${PYTHONPATH}` so LiteLLM can import the module.

**Verification**:

```bash
# Before the fix — fails:
curl -X POST https://<CLOUDFRONT_DOMAIN>/v1/messages \
  -H "Authorization: Bearer <KEY>" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":100,
       "messages":[{"role":"user","content":"hi"}],
       "context_management":{"edits":[{"type":"clear_tool_uses_20250919"}]}}'
# → 400 Extra inputs are not permitted

# After the fix — succeeds (same request returns 200 with normal Anthropic response).
```

**When can I remove it?** Once Bedrock adds native support for `context_management` on the Invoke endpoint (track the LiteLLM main branch for upstream Bedrock transform updates). Until then, leave the callback in place.
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
