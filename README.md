# LiteLLM Gateway - AWS Deployment (Aurora Serverless v2)

> Forked from [zhuangyq008/litellm-on-aws](https://github.com/zhuangyq008/litellm-on-aws) — replaced RDS PostgreSQL with **Aurora Serverless v2** for automatic scaling and cost optimization.

## Architecture

```
Internet -> CloudFront (HTTPS) -> ALB (HTTP:80, dual-AZ) -> ECS Fargate (private subnets, 2 replicas)
                                          |-> Aurora Serverless v2 PostgreSQL 16.6 (0.5-4 ACU, Multi-AZ)
                                          |-> ElastiCache Redis Serverless (TLS)
                                          |-> AWS Bedrock (IAM Role)
```

## Key Changes from Original

| Component | Original | This Fork |
|---|---|---|
| Database | RDS PostgreSQL 16.13 (db.m7g.large, fixed) | Aurora Serverless v2 (0.5-4 ACU, auto-scaling) |
| Scaling | Manual instance resize | Automatic 0.5 → 4 ACU based on load |
| HA | Multi-AZ standby (no read traffic) | 2 instances (writer + reader) with failover |
| Cost | ~$200/month (m7g.large always-on) | Pay per ACU-hour, scales to 0.5 ACU at idle |
| Storage | gp3, manual allocation 50-200GB | Aurora auto-expanding, no pre-allocation |

## Access

| Resource | Endpoint |
|---|---|
| LiteLLM Gateway (HTTPS) | `https://<YOUR-CLOUDFRONT-DOMAIN>` |
| LiteLLM Gateway (ALB) | `http://<YOUR-ALB-DNS>` |
| Health Check | `GET /health/liveliness` |
| Model Info | `GET /model/info` (requires auth) |
| Chat Completions | `POST /chat/completions` (OpenAI-compatible) |

## Authentication

Master key stored in Secrets Manager: `litellm/default/master-key`

Retrieve it:
```bash
aws secretsmanager get-secret-value \
  --secret-id litellm/default/master-key \
  --region us-east-1 \
  --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])"
```

Use in API calls:
```bash
curl http://<YOUR-ALB-DNS>/chat/completions \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-opus",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 200
  }'
```

## Available Models

| Model Name | Provider | Model ID |
|---|---|---|
| `bedrock-claude-opus` | AWS Bedrock | `us.anthropic.claude-opus-4-6-v1` |
| `bedrock-claude-haiku` | AWS Bedrock | `us.anthropic.claude-haiku-4-5-20251001-v1:0` |
| `gpt-4o` | OpenAI | `openai/gpt-4o` |
| `gpt-4o-mini` | OpenAI | `openai/gpt-4o-mini` |
| `gpt-4.1` | OpenAI | `openai/gpt-4.1` |
| `claude-sonnet-4-20250514` | Anthropic API | `anthropic/claude-sonnet-4-20250514` |
| `claude-haiku-4-5-20251001` | Anthropic API | `anthropic/claude-haiku-4-5-20251001` |
| `gemini-2.0-flash` | Google | `gemini/gemini-2.0-flash` |
| `gemini-2.5-pro` | Google | `gemini/gemini-2.5-pro-preview-05-06` |

Bedrock models use IAM Task Role (no API key needed). Other providers require API keys in Secrets Manager.

## Deployment

```bash
git clone https://github.com/cn-ljh/litellm-on-aws-1.git
cd litellm-on-aws-1
chmod +x deploy.sh
./deploy.sh
```

### Aurora Serverless v2 Scaling Parameters

You can customize ACU range via CloudFormation parameters in `cfn/03-data.yaml`:

| Parameter | Default | Description |
|---|---|---|
| `MinACU` | 0.5 | Minimum Aurora Capacity Units (cost savings at idle) |
| `MaxACU` | 4 | Maximum Aurora Capacity Units (peak performance) |

> **Tip**: For dev/test, `MinACU=0.5 / MaxACU=2` is sufficient. For production, consider `MinACU=1 / MaxACU=16`.

## Audit Logging (DynamoDB)

All API calls (success and failure) are logged to DynamoDB table `litellm-gw-audit-log`.

Each record includes: request id, model, messages, response, token usage, timestamps, caller metadata.

```bash
# Check audit log count
aws dynamodb scan --table-name litellm-gw-audit-log --region us-east-1 --select COUNT

# View recent logs
aws dynamodb scan --table-name litellm-gw-audit-log --region us-east-1 --max-items 5 \
  --projection-expression "id, model, call_type, startTime, #u" \
  --expression-attribute-names '{"#u":"usage"}'
```

Table features: PAY_PER_REQUEST billing, TTL support, Point-in-Time Recovery enabled.

## Update API Keys

```bash
aws secretsmanager update-secret --secret-id litellm/default/openai \
  --secret-string '{"api_key":"sk-xxx"}' --region us-east-1

aws secretsmanager update-secret --secret-id litellm/default/anthropic \
  --secret-string '{"api_key":"sk-ant-xxx"}' --region us-east-1

aws secretsmanager update-secret --secret-id litellm/default/gemini \
  --secret-string '{"api_key":"AIxxx"}' --region us-east-1

# Restart ECS to pick up new secrets
aws ecs update-service --cluster litellm-gw-cluster --service litellm-gw-service \
  --force-new-deployment --region us-east-1
```

## CloudFormation Stacks

| Stack | Resources |
|---|---|
| `litellm-gw-vpc` | VPC, 2 public + 2 private subnets, IGW, NAT GW |
| `litellm-gw-secrets` | Secrets Manager (tenant/provider namespace) |
| `litellm-gw-data` | **Aurora Serverless v2 PostgreSQL**, ElastiCache Redis Serverless, S3 config bucket, DynamoDB audit log |
| `litellm-gw-ecs` | ECS Fargate cluster, ALB, Task Definition, CloudWatch logs |
| `litellm-gw-cloudfront` | CloudFront distribution (HTTPS, HTTP/2+3) |

## Troubleshooting

### 1. Aurora PostgreSQL engine version not available
- **Symptom**: Stack creation fails with engine version error
- **Fix**: Check available versions: `aws rds describe-db-engine-versions --engine aurora-postgresql --query "DBEngineVersions[?starts_with(EngineVersion,'16')].EngineVersion"`

### 2. ECS worker processes crash (OOM)
- **Symptom**: Logs show `Child process [xxx] died` repeatedly
- **Fix**: Increase task memory from 2048MB to 4096MB, reduce `--num_workers` to 2

### 3. Bedrock models require inference profiles
- **Symptom**: `BedrockException - on-demand throughput isn't supported`
- **Fix**: Use cross-region inference profile IDs (prefix `us.`)

### 4. ALB Listener lost after stack delete/recreate
- **Symptom**: ALB exists but no listener, `Connection refused`
- **Fix**: deploy.sh includes self-heal logic; or manually create listener

### 5. ElastiCache Serverless delete fails during stack rollback
- **Symptom**: Stack delete fails with "not in an available state"
- **Fix**: Wait for cache to reach `available` state, then retry

### 6. Aurora scaling takes time under sudden load
- **Symptom**: Slow queries during rapid scale-up
- **Fix**: Increase `MinACU` to avoid cold-start latency; Aurora scales incrementally
