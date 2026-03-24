# LiteLLM Gateway 使用说明 (Aurora Serverless v2)

> 🚀 本文档为 LiteLLM Gateway (Aurora Serverless v2 版本) 的使用说明。网关已部署在 AWS us-east-1 区域，提供 OpenAI 兼容的统一大模型 API 接口。

---

## 访问信息

| 资源 | 地址 |
|------|------|
| **HTTPS 入口 (推荐)** | `https://dhbhkord7llum.cloudfront.net` |
| ALB 内网入口 | `http://litellm-gw-alb-2034477846.us-east-1.elb.amazonaws.com` |
| 健康检查 | `GET /health/liveliness` |
| 模型列表 | `GET /model/info` (需认证) |
| Chat Completions | `POST /chat/completions` (OpenAI 兼容) |
| CloudFront Distribution ID | `E2EKNSUJQWR7Y0` |
| AWS 账户 | `778346837945` / `us-east-1` |

---

## 认证方式

Master Key 存储在 AWS Secrets Manager 中，获取方式：

```bash
aws secretsmanager get-secret-value \
  --secret-id litellm/default/master-key \
  --region us-east-1 \
  --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])"
```

> 🔐 **Master Key 是管理员凭证，请妥善保管。** 所有 API 调用都需要在 Header 中携带 `Authorization: Bearer <MASTER_KEY>`。

---

## 可用模型 (10 个)

### Bedrock 模型 (IAM Role 认证, 无需 API Key)

| 调用名称 | 模型 ID | 定位 |
|----------|---------|------|
| `bedrock-claude-opus` | `us.anthropic.claude-opus-4-6-v1` | 最强能力，复杂推理 |
| `bedrock-claude-sonnet` | `us.anthropic.claude-sonnet-4-6` | **性价比最优，日常推荐** |
| `bedrock-claude-haiku` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | 最快最便宜，轻量任务 |

### OpenAI 模型

| 调用名称 | 模型 ID |
|----------|---------|
| `gpt-4o` | `openai/gpt-4o` |
| `gpt-4o-mini` | `openai/gpt-4o-mini` |
| `gpt-4.1` | `openai/gpt-4.1` |

### Anthropic API 模型

| 调用名称 | 模型 ID |
|----------|---------|
| `claude-sonnet-4-20250514` | `anthropic/claude-sonnet-4-20250514` |
| `claude-haiku-4-5-20251001` | `anthropic/claude-haiku-4-5-20251001` |

### Google Gemini 模型

| 调用名称 | 模型 ID |
|----------|---------|
| `gemini-2.0-flash` | `gemini/gemini-2.0-flash` |
| `gemini-2.5-pro` | `gemini/gemini-2.5-pro-preview-05-06` |

> 💡 **Bedrock 模型**（bedrock-claude-*）通过 IAM Task Role 认证，无需额外 API Key，开箱即用。其他提供商需在 Secrets Manager 中配置 API Key。

---

## 快速开始

### 1. 健康检查

```bash
curl https://dhbhkord7llum.cloudfront.net/health/liveliness
# 返回: "I'm alive!"
```

### 2. 调用 Bedrock Claude Sonnet (推荐)

```bash
curl https://dhbhkord7llum.cloudfront.net/chat/completions \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-sonnet",
    "messages": [{"role": "user", "content": "你好，请介绍一下你自己"}],
    "max_tokens": 500
  }'
```

### 3. 调用 Bedrock Claude Opus (最强)

```bash
curl https://dhbhkord7llum.cloudfront.net/chat/completions \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-opus",
    "messages": [{"role": "user", "content": "分析AWS Well-Architected Framework的六大支柱"}],
    "max_tokens": 2000
  }'
```

### 4. Python SDK 调用 (OpenAI 兼容)

```python
from openai import OpenAI

client = OpenAI(
    api_key="<MASTER_KEY>",
    base_url="https://dhbhkord7llum.cloudfront.net"
)

response = client.chat.completions.create(
    model="bedrock-claude-sonnet",
    messages=[{"role": "user", "content": "Hello!"}],
    max_tokens=200
)
print(response.choices[0].message.content)
```

### 5. 流式响应

```bash
curl https://dhbhkord7llum.cloudfront.net/chat/completions \
  -H "Authorization: Bearer <MASTER_KEY>" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-sonnet",
    "messages": [{"role": "user", "content": "写一首关于AWS的诗"}],
    "max_tokens": 500,
    "stream": true
  }'
```

---

## 如何更新模型 ID

当 AWS Bedrock 发布新模型或模型版本更新时，按以下步骤操作：

### 步骤 1: 查看可用的 Bedrock 推理配置

```bash
# 列出所有 Claude 模型的 cross-region inference profiles
aws bedrock list-inference-profiles --region us-east-1 --type SYSTEM_DEFINED \
  --query "inferenceProfileSummaries[?contains(inferenceProfileName,'Claude')].{Name:inferenceProfileName,ID:inferenceProfileId}" \
  --output table
```

### 步骤 2: 下载当前配置

```bash
aws s3 cp s3://litellm-gw-config-778346837945/litellm-config.yaml /tmp/litellm-config.yaml --region us-east-1
```

### 步骤 3: 编辑配置文件

```bash
vim /tmp/litellm-config.yaml
```

修改 `model_list` 中对应模型的 `model` 字段。例如将 Sonnet 从 4.6 升级到新版本：

```yaml
  # 修改前
  - model_name: bedrock-claude-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-6
      aws_region_name: us-east-1

  # 修改后（假设新版本 ID）
  - model_name: bedrock-claude-sonnet
    litellm_params:
      model: bedrock/us.anthropic.claude-sonnet-4-7-v1
      aws_region_name: us-east-1
```

**添加新模型**只需在 `model_list` 中新增条目：

```yaml
  - model_name: bedrock-claude-new-model
    litellm_params:
      model: bedrock/<新模型的 inference profile ID>
      aws_region_name: us-east-1
```

> ⚠️ **注意**: Bedrock 模型使用 `bedrock/` 前缀 + cross-region inference profile ID (格式 `us.anthropic.xxx`)。不要使用 `arn:` 格式。

### 步骤 4: 上传并重启

```bash
# 上传新配置
aws s3 cp /tmp/litellm-config.yaml \
  s3://litellm-gw-config-778346837945/litellm-config.yaml --region us-east-1

# 重启 ECS 服务（滚动更新，零停机）
aws ecs update-service --cluster litellm-gw-cluster --service litellm-gw-service \
  --force-new-deployment --region us-east-1
```

### 步骤 5: 验证

```bash
# 等待 2-3 分钟后验证
MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id litellm/default/master-key --region us-east-1 --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])")

# 检查模型列表
curl -s https://dhbhkord7llum.cloudfront.net/v1/models \
  -H "Authorization: Bearer $MASTER_KEY" | python3 -m json.tool

# 测试调用
curl -s https://dhbhkord7llum.cloudfront.net/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"bedrock-claude-sonnet","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}'
```

---

## 如何创建用户 Keys (Virtual Keys)

LiteLLM 支持为不同用户/团队创建独立的 API Key（Virtual Keys），实现：
- **用量追踪**：按 Key 统计 token 消耗
- **预算控制**：为每个 Key 设置消费上限
- **模型限制**：限制 Key 可以访问的模型
- **速率限制**：限制 Key 的 RPM/TPM

### 方法一: 使用 API 创建 Key

```bash
MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id litellm/default/master-key --region us-east-1 --query SecretString --output text | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])")

# 创建一个基础 Key（无限制）
curl -s https://dhbhkord7llum.cloudfront.net/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "team-backend",
    "duration": "30d",
    "max_budget": 100.0,
    "metadata": {"team": "backend", "owner": "john"}
  }' | python3 -m json.tool
```

### 方法二: 创建带模型限制的 Key

```bash
# 只允许使用 Bedrock 模型
curl -s https://dhbhkord7llum.cloudfront.net/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "intern-limited",
    "models": ["bedrock-claude-haiku", "bedrock-claude-sonnet"],
    "max_budget": 10.0,
    "duration": "7d",
    "tpm_limit": 100000,
    "rpm_limit": 60,
    "metadata": {"user": "intern", "purpose": "testing"}
  }' | python3 -m json.tool
```

**返回值** 中的 `key` 就是用户的 API Key，格式 `sk-xxx`。

### 方法三: 为团队创建 Key

```bash
# 1. 先创建团队
curl -s https://dhbhkord7llum.cloudfront.net/team/new \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "platform-team",
    "max_budget": 500.0,
    "models": ["bedrock-claude-opus", "bedrock-claude-sonnet", "bedrock-claude-haiku"]
  }' | python3 -m json.tool

# 返回中的 team_id 用于下一步

# 2. 为团队成员创建 Key
curl -s https://dhbhkord7llum.cloudfront.net/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "alice-key",
    "team_id": "<TEAM_ID>",
    "max_budget": 50.0
  }' | python3 -m json.tool
```

### 管理已有 Keys

```bash
# 列出所有 Keys
curl -s https://dhbhkord7llum.cloudfront.net/key/list \
  -H "Authorization: Bearer $MASTER_KEY" | python3 -m json.tool

# 查看 Key 详情和用量
curl -s https://dhbhkord7llum.cloudfront.net/key/info \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key": "sk-xxx"}' | python3 -m json.tool

# 更新 Key（修改预算/模型）
curl -s https://dhbhkord7llum.cloudfront.net/key/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key": "sk-xxx",
    "max_budget": 200.0,
    "models": ["bedrock-claude-opus", "bedrock-claude-sonnet"]
  }' | python3 -m json.tool

# 删除 Key
curl -s https://dhbhkord7llum.cloudfront.net/key/delete \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"keys": ["sk-xxx"]}' | python3 -m json.tool
```

### 用户使用自己的 Key 调用

```bash
# 用户用自己的 sk-xxx Key 替代 Master Key
curl https://dhbhkord7llum.cloudfront.net/chat/completions \
  -H "Authorization: Bearer sk-xxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "bedrock-claude-sonnet",
    "messages": [{"role": "user", "content": "Hello!"}],
    "max_tokens": 200
  }'
```

---

## 配置第三方 API Key

Bedrock 模型通过 IAM Role 免 Key，但 OpenAI/Anthropic/Gemini 需要配置 API Key：

```bash
# OpenAI
aws secretsmanager update-secret --secret-id litellm/default/openai \
  --secret-string '{"api_key":"sk-proj-xxx"}' --region us-east-1

# Anthropic
aws secretsmanager update-secret --secret-id litellm/default/anthropic \
  --secret-string '{"api_key":"sk-ant-xxx"}' --region us-east-1

# Google Gemini
aws secretsmanager update-secret --secret-id litellm/default/gemini \
  --secret-string '{"api_key":"AIxxx"}' --region us-east-1

# 重启 ECS 使密钥生效
aws ecs update-service --cluster litellm-gw-cluster --service litellm-gw-service \
  --force-new-deployment --region us-east-1
```

---

## 架构概览

```
┌─────────┐     HTTPS      ┌──────────────┐     HTTP:80     ┌─────────────────┐
│  客户端  │ ──────────────> │  CloudFront  │ ──────────────> │       ALB       │
└─────────┘                 └──────────────┘                 └────────┬────────┘
                                                                      │ :4000
                                                        ┌─────────────┼─────────────┐
                                                        │             │             │
                                                   ┌────▼────┐  ┌────▼────┐       │
                                                   │ ECS #1  │  │ ECS #2  │       │
                                                   │ Fargate │  │ Fargate │       │
                                                   └────┬────┘  └────┬────┘       │
                                                        │             │             │
                            ┌───────────────────────────┼─────────────┤             │
                            │                           │             │             │
                    ┌───────▼───────┐          ┌────────▼──────┐  ┌──▼─────────┐  │
                    │ Aurora SL v2  │          │ Redis SL      │  │ Bedrock    │  │
                    │ PG 16.6       │          │ Serverless    │  │ Claude/etc │  │
                    │ 0.5-4 ACU     │          └───────────────┘  └────────────┘  │
                    └───────────────┘                                              │
                                                                    ┌──────────────▼┐
                                                                    │  DynamoDB     │
                                                                    │  审计日志      │
                                                                    └───────────────┘
```

### 关键组件

| 组件 | AWS 服务 | 规格说明 |
|------|----------|----------|
| 计算层 | ECS Fargate | 1 vCPU / 4GB 内存 / 2 副本，私有子网 |
| 数据库 | Aurora Serverless v2 | PostgreSQL 16.6, 0.5-4 ACU 自动伸缩, 双实例 |
| 缓存 | ElastiCache Redis | Serverless, TLS 加密, 自动扩缩容 |
| CDN | CloudFront | HTTPS 终结, HTTP/2+3, 全球边缘加速 |
| 审计日志 | DynamoDB | 按需计费, 全量记录, TTL + PITR |
| 密钥管理 | Secrets Manager | 租户/提供商命名空间, 自动生成 Master Key |

---

## 运维操作

### 查看审计日志

```bash
# 总数
aws dynamodb scan --table-name litellm-gw-audit-log --region us-east-1 --select COUNT

# 最近 5 条
aws dynamodb scan --table-name litellm-gw-audit-log --region us-east-1 --max-items 5 \
  --projection-expression "id, model, call_type, startTime, #u" \
  --expression-attribute-names '{"#u":"usage"}'
```

### 查看应用日志

```bash
# 实时追踪
aws logs tail /ecs/litellm-gw --follow --region us-east-1

# 搜索错误
aws logs filter-log-events --log-group-name /ecs/litellm-gw \
  --filter-pattern "ERROR" --start-time $(date -d '1 hour ago' +%s000) \
  --region us-east-1
```

### 扩缩容

```bash
# ECS 副本数调整
aws ecs update-service --cluster litellm-gw-cluster --service litellm-gw-service \
  --desired-count 4 --region us-east-1

# Aurora ACU 范围调整
aws rds modify-db-cluster --db-cluster-identifier litellm-gw-aurora-cluster \
  --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=16 \
  --apply-immediately --region us-east-1
```

### 查看 CloudFormation 堆栈状态

```bash
aws cloudformation describe-stacks --region us-east-1 \
  --query "Stacks[?starts_with(StackName,'litellm-gw')].{Name:StackName,Status:StackStatus}" \
  --output table
```

---

## 清理/卸载

> ⚠️ 按逆序删除堆栈。Aurora 启用了删除保护需先关闭；S3 桶需手动清空。

```bash
# 1. 关闭 Aurora 删除保护
aws rds modify-db-cluster --db-cluster-identifier litellm-gw-aurora-cluster \
  --no-deletion-protection --apply-immediately --region us-east-1

# 2. 按逆序删除堆栈
for stack in litellm-gw-cloudfront litellm-gw-ecs litellm-gw-data litellm-gw-secrets litellm-gw-vpc; do
  aws cloudformation delete-stack --stack-name $stack --region us-east-1
  aws cloudformation wait stack-delete-complete --stack-name $stack --region us-east-1
  echo "Deleted: $stack"
done

# 3. 清空 S3 桶（如果堆栈删除失败）
aws s3 rm s3://litellm-gw-config-778346837945 --recursive --region us-east-1
```

---

## 成本估算 (月)

| 组件 | 估算 (USD) | 说明 |
|------|-----------|------|
| Aurora Serverless v2 | $30~$150 | 空闲 0.5 ACU ≈ $43; 中等负载 2 ACU ≈ $172 |
| ECS Fargate (2副本) | ~$75 | 1 vCPU / 4GB × 2 |
| ElastiCache Redis | ~$20 | Serverless 按用量 |
| NAT Gateway | ~$35 | $0.045/hr + 数据传输 |
| CloudFront + 其他 | ~$10 | 按请求量 |
| **合计** | **$170~$290** | 不含模型调用费 (Bedrock/OpenAI 按 token 另计) |

> 💰 相比原版 RDS db.m7g.large (~$200/月仅数据库)，Aurora Serverless v2 在低负载时可节省约 **70%** 数据库成本。
