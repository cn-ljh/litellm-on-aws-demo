# LiteLLM on AWS — 统一大模型 API 网关

[English](README.md) | **中文**

在 AWS 上部署 [LiteLLM Proxy](https://github.com/BerriAI/litellm)，提供 OpenAI 兼容的统一 API 接口，代理 AWS Bedrock、OpenAI、Anthropic、Google Gemini 等多家模型服务商。

> 基于 [zhuangyq008/litellm-on-aws](https://github.com/zhuangyq008/litellm-on-aws) 改造，将 RDS PostgreSQL 替换为 **Aurora Serverless v2**，实现自动伸缩和成本优化。

## 特性

- **OpenAI 兼容 API** — 一个 endpoint 统一所有 LLM 提供商
- **Aurora Serverless v2** — 数据库自动伸缩（0.5–16 ACU），按需付费
- **Bedrock 免配置** — 通过 IAM Role 认证，无需 API Key
- **内置审计日志** — 所有调用自动记录到 PostgreSQL，零额外成本
- **Virtual Keys** — 按用户/团队分配 API Key，支持预算和速率限制
- **一键部署** — 5 个 CloudFormation 堆栈，全自动化

---

## 前置条件

### 1. AWS 账户和权限

| 要求 | 说明 |
|------|------|
| **AWS 账户** | 需要一个可用的 AWS 账户 |
| **IAM 权限** | 部署用户/角色需要 **Administrator** 或同等权限 |
| | 涉及的服务：VPC、EC2、ECS、RDS、ElastiCache、S3、CloudFront、Secrets Manager、IAM、CloudWatch、Bedrock |
| **服务配额** | 确认目标区域的 VPC、EIP、NAT Gateway 配额充足 |

### 2. 开发工具

| 工具 | 最低版本 | 安装方式 |
|------|---------|---------|
| **AWS CLI** | v2.x | [安装指南](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| **Python** | 3.8+ | 用于解析 JSON 输出 |
| **bash** | 4.0+ | 运行部署脚本 |

```bash
# 验证 AWS CLI 已配置
aws sts get-caller-identity
aws configure get region
```

### 3. Bedrock 模型访问（重要）

Bedrock 模型默认**未开通**，需要在控制台手动申请：

1. 登录 [AWS 控制台](https://console.aws.amazon.com/bedrock/home#/modelaccess)
2. 选择部署目标区域（如 `us-east-1`）
3. 点击 **Manage model access** → 勾选以下模型 → **Save changes**
   - ✅ Anthropic Claude Opus 4.6
   - ✅ Anthropic Claude Sonnet 4.6
   - ✅ Anthropic Claude Haiku 4.5
4. 等待状态变为 **Access granted**（通常几分钟内）

> ⚠️ **如果跳过这一步，Bedrock 模型的 API 调用会返回 403 错误。**

### 4. 第三方 API Key（可选）

如果需要使用 OpenAI、Anthropic API、Gemini 等非 Bedrock 模型：

| 提供商 | 获取地址 |
|--------|---------|
| OpenAI | https://platform.openai.com/api-keys |
| Anthropic | https://console.anthropic.com/settings/keys |
| Google Gemini | https://aistudio.google.com/apikey |

> 如果只使用 Bedrock 模型，可跳过此步骤。

---

## 架构

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          AWS Cloud — VPC (10.0.0.0/16)                       │
│                                                                              │
│  ┌─────────┐    ┌───────────────┐    ┌────────────┐    ┌─────────────────┐  │
│  │         │    │  CloudFront   │    │    ALB     │    │ Private Subnets │  │
│  │  客户端  │───▶│   (HTTPS)    │───▶│ (HTTP:80)  │───▶│                 │  │
│  │ curl /  │    │   TLS 终结    │    │  双 AZ     │    │ ┌─────┐ ┌─────┐│  │
│  │ SDK /   │    │   HTTP/2+3   │    │            │    │ │ECS  │ │ECS  ││  │
│  │ Claude  │    └───────────────┘    └────────────┘    │ │ #1  │ │ #2  ││  │
│  │ Code    │                                           │ │1C/4G│ │1C/4G││  │
│  └─────────┘                                           │ └──┬──┘ └──┬──┘│  │
│                                                        │    │       │    │  │
│                                                        │    ▼       ▼    │  │
│                                                        │ ┌────────────┐ │  │
│         ┌─────────────────┐                            │ │  Aurora    │ │  │
│         │ Secrets Manager │                            │ │ Serverless │ │  │
│         │ ┌─────────────┐ │                            │ │  v2 (PG16) │ │  │
│         │ │ Master Key  │ │                            │ │ 0.5─4 ACU │ │  │
│         │ │ OpenAI Key  │ │                            │ │ W + R     │ │  │
│         │ │Anthropic Key│ │                            │ └────────────┘ │  │
│         │ │ Gemini Key  │ │                            │ ┌────────────┐ │  │
│         │ └─────────────┘ │                            │ │Valkey (TLS) │ │  │
│         └─────────────────┘                            │ └────────────┘ │  │
│                                                        └─────────────────┘  │
│         ┌──────────────────────────────────────────────┐                    │
│         │               LLM 模型提供商                  │                    │
│         │                                              │                    │
│         │  ┌──────────┐  ┌────────┐  ┌──────────────┐ │  ┌──────────────┐  │
│         │  │ Bedrock  │  │ OpenAI │  │  Anthropic   │ │  │    S3        │  │
│         │  │(IAM 认证) │  │(APIKey)│  │  (API Key)   │ │  │ litellm     │  │
│         │  └──────────┘  └────────┘  └──────────────┘ │  │ -config.yaml│  │
│         │  ┌──────────────────────────────────────┐   │  └──────────────┘  │
│         │  │          Google Gemini (API Key)      │   │                    │
│         │  └──────────────────────────────────────┘   │                    │
│         └──────────────────────────────────────────────┘                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

| 组件 | AWS 服务 | 规格 |
|------|----------|------|
| CDN/HTTPS | CloudFront | HTTPS 终结, HTTP/2+3 |
| 负载均衡 | ALB | 双 AZ, 内部 |
| 计算 | ECS Fargate | 1 vCPU / 4GB × 2 副本 |
| 数据库 | Aurora Serverless v2 | PostgreSQL 16, 0.5-4 ACU |
| 缓存 | ElastiCache Valkey | Serverless, TLS |
| 审计日志 | PostgreSQL SpendLogs | 内置, 零额外成本 |
| 密钥 | Secrets Manager | 自动生成 Master Key |

---

## 快速部署（20-25 分钟）

### 第 1 步：克隆代码

```bash
git clone https://github.com/cn-ljh/litellm-on-aws-demo.git
cd litellm-on-aws-demo
```

### 第 2 步：（可选）修改配置

**模型列表** — 编辑 `config/litellm-config.yaml`，按需增删模型。

**部署参数** — 可通过环境变量自定义：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `PROJECT_NAME` | `litellm-gw` | 所有资源的命名前缀 |
| `TENANT_NAME` | `default` | Secrets Manager 命名空间 |
| `AWS_REGION` | `us-east-1` | 部署区域 |
| `LITELLM_VERSION` | *(自动检测最新稳定版)* | 指定版本，如 `v1.82.3-stable.patch.2` |

### 第 3 步：执行部署

```bash
chmod +x deploy.sh
./deploy.sh
```

或指定自定义参数：

```bash
PROJECT_NAME=my-llm-gw TENANT_NAME=myteam AWS_REGION=us-west-2 ./deploy.sh
```

部署过程分 5 个阶段：

| 阶段 | 耗时 | 创建的资源 |
|------|------|-----------|
| 1. VPC 网络 | ~2 分钟 | VPC、子网、NAT |
| 2. 密钥管理 | ~1 分钟 | Secrets Manager |
| 3. 数据层 | ~10-15 分钟 | Aurora、Valkey、S3 |
| 4. 应用层 | ~3-5 分钟 | ECS、ALB、IAM |
| 5. CDN 层 | ~3-5 分钟 | CloudFront |

部署完成后，脚本会输出：
- ✅ CloudFront HTTPS 地址
- ✅ ALB 内网地址
- ✅ 后续操作提示

### 第 4 步：配置 API Key（可选）

> 如果只使用 Bedrock 模型，跳过此步骤。

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

# 重启 ECS 使密钥生效
aws ecs update-service \
  --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-service \
  --force-new-deployment \
  --region <YOUR_REGION>
```

### 第 5 步：验证部署

```bash
# 1. 获取 Master Key
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id litellm/<TENANT_NAME>/master-key \
  --region <YOUR_REGION> \
  --query SecretString --output text \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['master_key'])")

# 2. 健康检查
curl https://<YOUR_CLOUDFRONT_DOMAIN>/health/liveliness
# 返回: "I'm alive!"

# 3. 测试调用 (Bedrock Claude Sonnet)
curl https://<YOUR_CLOUDFRONT_DOMAIN>/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "你好！"}],
    "max_tokens": 200
  }'
```

---

## 默认模型

### Bedrock 模型（IAM 认证，免 API Key）

| 调用名称 | 模型 ID | 定位 |
|----------|---------|------|
| `claude-opus-4-6` | `us.anthropic.claude-opus-4-6-v1` | 最强能力，复杂推理 |
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` | **性价比最优，推荐** |
| `claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | 最快最便宜 |

### 第三方模型（需配置 API Key）

| 调用名称 | 提供商 | 模型 ID |
|----------|--------|---------|
| `gpt-4o` | OpenAI | `openai/gpt-4o` |
| `gpt-4o-mini` | OpenAI | `openai/gpt-4o-mini` |
| `gpt-4.1` | OpenAI | `openai/gpt-4.1` |
| `claude-sonnet-4-20250514` | Anthropic API | `anthropic/claude-sonnet-4-20250514` |
| `claude-haiku-4-5-20251001` | Anthropic API | `anthropic/claude-haiku-4-5-20251001` |
| `gemini-2.0-flash` | Google | `gemini/gemini-2.0-flash` |
| `gemini-2.5-pro` | Google | `gemini/gemini-2.5-pro-preview-05-06` |

---

## 使用示例

### curl 调用

```bash
curl https://<YOUR_CLOUDFRONT_DOMAIN>/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "用三句话介绍 AWS Bedrock"}],
    "max_tokens": 500
  }'
```

### Python SDK（OpenAI 兼容）

```python
from openai import OpenAI

client = OpenAI(
    api_key="<MASTER_KEY>",
    base_url="https://<YOUR_CLOUDFRONT_DOMAIN>"
)

response = client.chat.completions.create(
    model="claude-sonnet-4-6",
    messages=[{"role": "user", "content": "你好！"}],
    max_tokens=200
)
print(response.choices[0].message.content)
```

### 流式响应

```bash
curl https://<YOUR_CLOUDFRONT_DOMAIN>/chat/completions \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "写一首关于云计算的诗"}],
    "max_tokens": 500,
    "stream": true
  }'
```

---

## 配合 Claude Code 使用

[Claude Code](https://docs.anthropic.com/en/docs/claude-code) 可以连接 LiteLLM 网关作为自定义后端。支持两种配置方式：

### 方式一：环境变量

```bash
export ANTHROPIC_AUTH_TOKEN="sk-xxx"                          # LiteLLM Virtual Key
export ANTHROPIC_BASE_URL="https://<YOUR_CLOUDFRONT_DOMAIN>"  # 网关地址
export ANTHROPIC_DEFAULT_SONNET_MODEL="claude-sonnet-4-6"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="claude-haiku-4-5"
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-6"
```

> 添加到 `~/.bashrc` 或 `~/.zshrc` 中可持久化。

### 方式二：配置文件（`~/.claude/settings.json`）

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

配置后，Claude Code 的所有请求都将通过 LiteLLM 网关路由到 Bedrock，无需 Anthropic API Key。

---

## 用户和 Key 管理

### 创建用户 Key

```bash
# 基础 Key（30 天有效，$100 预算）
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "team-backend",
    "duration": "30d",
    "max_budget": 100.0
  }' | python3 -m json.tool
```

返回的 `key`（格式 `sk-xxx`）即为用户的 API Key。

### 限制模型和速率的 Key

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

### 团队管理

```bash
# 创建团队
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/team/new \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "team_alias": "platform-team",
    "max_budget": 500.0,
    "models": ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5"]
  }' | python3 -m json.tool

# 为团队成员创建 Key（使用上面返回的 team_id）
curl -s https://<YOUR_CLOUDFRONT_DOMAIN>/key/generate \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "key_alias": "member-key",
    "team_id": "<TEAM_ID>",
    "max_budget": 50.0
  }' | python3 -m json.tool
```

> ⚠️ **注意**：通过 LiteLLM UI 创建用户时，默认 `models: ["no-default-models"]` 会阻止所有模型调用。必须手动设置 models 列表。

---

## 运维操作

### 更新模型配置

```bash
# 1. 编辑模型配置
vim config/litellm-config.yaml

# 2. 上传到 S3
aws s3 cp config/litellm-config.yaml \
  s3://<PROJECT_NAME>-config-<ACCOUNT_ID>/litellm-config.yaml \
  --region <YOUR_REGION>

# 3. 滚动重启（零停机）
aws ecs update-service \
  --cluster <PROJECT_NAME>-cluster \
  --service <PROJECT_NAME>-service \
  --force-new-deployment \
  --region <YOUR_REGION>
```

### 查看审计日志

```bash
# 查看今日费用汇总
curl -s "https://<YOUR_CLOUDFRONT_DOMAIN>/spend/logs?start_date=$(date +%Y-%m-%d)&end_date=$(date -d '+1 day' +%Y-%m-%d)" \
  -H "Authorization: Bearer $MASTER_KEY" | python3 -m json.tool
```

### 扩缩容

```bash
# 调整 ECS 副本数
aws ecs update-service --cluster <PROJECT_NAME>-cluster --service <PROJECT_NAME>-service \
  --desired-count 4 --region <YOUR_REGION>

# 调整 Aurora ACU 范围
aws rds modify-db-cluster --db-cluster-identifier <PROJECT_NAME>-aurora-cluster \
  --serverless-v2-scaling-configuration MinCapacity=1,MaxCapacity=16 \
  --apply-immediately --region <YOUR_REGION>
```

### 查看应用日志

```bash
aws logs tail /ecs/<PROJECT_NAME> --follow --region <YOUR_REGION>
```

---

## 清理/卸载

> ⚠️ 按逆序删除。Aurora 启用了删除保护，需先关闭；S3 桶需手动清空。

```bash
# 1. 关闭 Aurora 删除保护
aws rds modify-db-cluster --db-cluster-identifier <PROJECT_NAME>-aurora-cluster \
  --no-deletion-protection --apply-immediately --region <YOUR_REGION>

# 2. 清空 S3 桶
aws s3 rm s3://<PROJECT_NAME>-config-<ACCOUNT_ID> --recursive --region <YOUR_REGION>

# 3. 按逆序删除堆栈
for stack in <PROJECT_NAME>-cloudfront <PROJECT_NAME>-ecs <PROJECT_NAME>-data <PROJECT_NAME>-secrets <PROJECT_NAME>-vpc; do
  aws cloudformation delete-stack --stack-name $stack --region <YOUR_REGION>
  aws cloudformation wait stack-delete-complete --stack-name $stack --region <YOUR_REGION>
  echo "已删除: $stack"
done
```

---

## 成本估算（月）

| 组件 | 费用 (USD) | 说明 |
|------|-----------|------|
| Aurora Serverless v2 | $30–$150 | 空闲 ~$43 (0.5 ACU)；中等负载 ~$172 |
| ECS Fargate (2副本) | ~$75 | 1 vCPU / 4GB × 2 |
| ElastiCache Valkey | ~$6 | Serverless (100MB min) |
| NAT Gateway | ~$35 | $0.045/hr + 流量 |
| CloudFront 等 | ~$10 | 按请求计费 |
| **基础设施合计** | **$170–$290** | 不含模型调用费 |

> 💰 相比原版 RDS db.m7g.large（仅数据库 ~$200/月），Aurora Serverless v2 在低负载时节省约 **70%** 数据库成本。

---

## 常见问题

### Q: 通过 UI 创建用户后，Key 报 "model not allowed"（403）

通过 LiteLLM Admin UI 创建用户时，界面没有模型选择框。用户的 `models` 默认值为 `["no-default-models"]`，**会阻止访问所有模型**——即使生成 Key 时选了模型也不行。

**方案 1：通过 API 修改用户的 models**

```bash
# 设为空数组 = 允许所有模型
curl https://<YOUR_CLOUDFRONT_DOMAIN>/user/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<USER_ID>", "models": []}'

# 或限制特定模型
curl https://<YOUR_CLOUDFRONT_DOMAIN>/user/update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"user_id": "<USER_ID>", "models": ["claude-sonnet-4-6", "claude-haiku-4-5"]}'
```

**方案 2：使用 Team 管理（推荐）**

创建 Team 时指定允许的模型，然后将用户分配到该 Team。Team 的模型权限会覆盖用户默认设置。

```bash
curl https://<YOUR_CLOUDFRONT_DOMAIN>/team/new \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"team_alias": "dev-team", "models": ["claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-6"]}'
```

> 这是 LiteLLM UI 的已知限制——创建用户界面没有提供模型选择器。


### Q: 部署报错 "engine version not available"

目标区域不支持该 PostgreSQL 版本。查询可用版本：
```bash
aws rds describe-db-engine-versions --engine aurora-postgresql \
  --query "DBEngineVersions[?starts_with(EngineVersion,'16')].EngineVersion" \
  --output text --region <YOUR_REGION>
```

### Q: ECS 任务反复重启 (OOM)

将 `cfn/04-ecs.yaml` 中的 `TaskMemory` 从 `2048` 改为 `4096`，`--num_workers` 保持 ≤ 2。

### Q: Bedrock 返回 "on-demand throughput isn't supported"

模型 ID 必须使用 cross-region inference profile 格式（`us.` 前缀）：
```yaml
# 错误 ❌  model: bedrock/anthropic.claude-opus-4-6-v1:0
# 正确 ✅  model: bedrock/us.anthropic.claude-opus-4-6-v1
```

### Q: Bedrock 返回 403 Forbidden

Bedrock 模型访问未开通。前往 [Bedrock 控制台](https://console.aws.amazon.com/bedrock/home#/modelaccess) 申请模型访问权限。

### Q: 部署需要哪些 IAM 权限？

最低权限需要覆盖：
- `cloudformation:*` — 管理堆栈
- `ec2:*` — VPC、子网、安全组、NAT
- `ecs:*` — 集群、服务、任务
- `rds:*` — Aurora 集群
- `elasticache:*` — Valkey Serverless
- `s3:*` — 配置桶
- `cloudfront:*` — CDN 分发
- `secretsmanager:*` — 密钥管理
- `iam:*` — ECS Task Role
- `logs:*` — CloudWatch 日志
- `bedrock:*` — 模型调用
- `elasticloadbalancing:*` — ALB

> 建议使用 **AdministratorAccess** 策略部署，部署完成后可收紧权限。

---

## 安全建议

| 项目 | 当前状态 | 建议 |
|------|---------|------|
| HTTPS | CloudFront TLS 终结 | 添加自定义域名 + ACM 证书 |
| ALB 访问 | 开放 | 通过 CloudFront 托管前缀列表或 WAF 限制 |
| Master Key | 自动生成 | 定期轮换，限制分发范围 |
| 数据库 | Multi-AZ + 加密 | 生产就绪 |
| Valkey | TLS 加密 | 生产就绪 |
| NAT | 单 AZ | 高可用场景添加第二个 NAT |

---

## 项目结构

```
litellm-on-aws-demo/
├── cfn/
│   ├── 01-vpc.yaml              # 网络层
│   ├── 02-secrets.yaml          # 密钥管理
│   ├── 03-data.yaml             # Aurora、Valkey、S3
│   ├── 04-ecs.yaml              # ECS、ALB、IAM
│   └── 05-cloudfront.yaml       # CloudFront
├── config/
│   └── litellm-config.yaml      # 模型路由配置
├── deploy.sh                    # 一键部署脚本
├── README.md                    # English
└── README_CN.md                 # 中文指南
```
