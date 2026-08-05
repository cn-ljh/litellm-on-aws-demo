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
- **ECS 自动伸缩** — 基于 CPU 利用率自动扩缩容（2–4 副本）
- **Graviton (ARM64)** — 使用 AWS Graviton 处理器，计算成本降低 20%
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
   - ✅ Anthropic Claude Opus 4.8
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
| 计算 | ECS Fargate (Graviton) | 0.5 vCPU / 4GB × 2 副本 |
| 数据库 | Aurora Serverless v2 | PostgreSQL 16, 0.5-4 ACU |
| 缓存 | ElastiCache Valkey | Serverless, TLS |
| 审计日志 | PostgreSQL SpendLogs | 内置, 零额外成本 |
| 密钥 | Secrets Manager | 自动生成 Master Key |

---

## 快速部署（20-25 分钟）

> **⚠️ 给 AI Agent / 自动化部署工具：** 运行 `deploy.sh` 前，**必须先与用户确认 Aurora PostgreSQL 引擎版本**。模板默认 `16.8`（PostgreSQL 16 LTS 版本，标准支持至 2029-02），已在 LiteLLM 的 Prisma 托管 schema 上充分验证。**不要擅自跳到 PostgreSQL 17.x** —— LiteLLM 曾报告 PG17 上 Prisma 首次建表失败（见 BerriAI/litellm#9400），任何升到 17.x 的决定都应经用户明确批准，并先验证全新 Prisma 迁移能通过。同时确认所选版本在目标区域可用（`aws rds describe-db-engine-versions --engine aurora-postgresql`）。通过环境变量 `AURORA_ENGINE_VERSION` 覆盖。

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

# 覆盖 Aurora 引擎版本（某区域没有默认的 16.8 时）
AURORA_ENGINE_VERSION=15.5 ./deploy.sh

# 一键部署并集成自建 SearXNG web search MCP 模块（需要 Docker）
DEPLOY_SEARXNG=1 ./deploy.sh

# 不部署 AgentCore Web Search（默认会部署，见下）
DEPLOY_AGENTCORE=0 ./deploy.sh
```

可选环境变量：

| 变量 | 默认 | 说明 |
|------|------|------|
| `AURORA_ENGINE_VERSION` | 模板默认 `16.8`（PG16 LTS） | 覆盖 Aurora 引擎版本（某区域无 16.8 时用） |
| `DEPLOY_AGENTCORE` | `1`（开） | 部署 AgentCore Web Search（托管 web search，`cfn/08`）并注册进 LiteLLM。Docker-free、无需 API key，**默认开启**。仅 `us-east-1` 生效，其它区自动跳过。设 `0` 关闭 |
| `SKIP_AGENTCORE_SYNC` | `0` | `DEPLOY_AGENTCORE=1` 时，设 `1` 只建 `cfn/08` 栈、稍后再手动注册 MCP server |
| `DEPLOY_SEARXNG` | `0`（关） | 额外构建并部署自建 SearXNG MCP 模块（**需要 Docker**） |
| `SEARXNG_IMAGE_TAG` | `v1` | SearXNG 镜像 tag |
| `SKIP_SEARXNG_SYNC` | `0` | `DEPLOY_SEARXNG=1` 时，设 `1` 跳过部署后的 MCP 注册 |

### AgentCore Web Search Tool（托管 web search，默认部署）

AWS Bedrock AgentCore 于 2026-06-17 GA 了托管的 Web Search 工具：Amazon 自建索引、分钟级更新、查询不出 AWS、零基础设施、无需 API key。本仓库通过 `cfn/08-agentcore-websearch.yaml` 接入，**`deploy.sh` 默认部署并集成进 LiteLLM**（`DEPLOY_AGENTCORE=1`），与自建 SearXNG MCP 并存、不替换。因为它 Docker-free 且无需密钥，所以默认开启（区别于需要 Docker、默认关闭的 SearXNG）。

架构要点：
- 建一个 **AgentCore Gateway**（`AuthorizerType: AWS_IAM`，MCP 协议）+ Web Search target（`connectorId: web-search`，工具名 `WebSearch`）。
- Gateway 自己用一个 service role（`InvokeGateway` + `InvokeWebSearch`，后者 resource 锁服务方 ARN `arn:aws:bedrock-agentcore:<region>:aws:tool/web-search.v1`）。
- **inbound 鉴权走 IAM，不发任何 key、不建 Cognito/Keycloak**：`cfn/08` 自动给 LiteLLM 的 ECS task role 加 `bedrock-agentcore:InvokeGateway`（task role 名通过 `Fn::ImportValue` 从 ECS 栈的 `${ProjectName}-ECSTaskRoleName` 导出值取得，无需手填）；LiteLLM 用 `auth_type=aws_sigv4`、凭证留空回落 boto3 chain（即吃 task role）对 Gateway 做 SigV4 签名。需 LiteLLM ≥ v1.80.18。
- **仅 `us-east-1` 可用**：在其它区域 `deploy.sh` 会打印 WARN 并自动跳过该步骤。

#### 默认随 `deploy.sh` 自动部署

核心部署完成后（CloudFront 之后），脚本的 Step 8 会自动：部署 `cfn/08` 栈 → 调 `scripts/sync-agentcore-websearch.sh` 把 Gateway 注册成 LiteLLM 的 `agentcore_websearch` MCP server。无需任何手动操作。关闭用 `DEPLOY_AGENTCORE=0 ./deploy.sh`；只建栈不注册用 `SKIP_AGENTCORE_SYNC=1`。

#### 手动/单独注册（栈已存在、或稍后补注册时）

```bash
# GATEWAY_ID 取自 cfn/08 栈输出 GatewayId（或 aws cloudformation describe-stacks 查询）
GATEWAY_ID=litellm-websearch-gw-xxxxxxxx \
  LITELLM_PROXY_URL=https://<你的-cloudfront-域名> \
  PROJECT_NAME=litellm-gw TENANT_NAME=default AWS_REGION=us-east-1 \
  ./scripts/sync-agentcore-websearch.sh
```

LiteLLM 里工具名为 `web-search-tool___WebSearch`，与 SearXNG 的 `web_search`、Tavily、Exa 并列。客户端验证（模型自主调用）：
```bash
curl -s -X POST https://<cloudfront域名>/v1/responses \
  -H "Authorization: Bearer <master_key>" -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5","input":"用 web 搜索告诉我今天的某条新闻并给出来源 URL",
       "tools":[{"type":"mcp","server_label":"agentcore_websearch","server_url":"litellm_proxy","require_approval":"never"}]}'
```

部署过程分 6 个阶段（Step 7 SearXNG 可选、需 Docker）：

| 阶段 | 耗时 | 创建的资源 |
|------|------|-----------|
| 1. VPC 网络 | ~2 分钟 | VPC、子网、NAT |
| 2. 密钥管理 | ~1 分钟 | Secrets Manager |
| 3. 数据层 | ~10-15 分钟 | Aurora、Valkey、S3 |
| 4. 应用层 | ~3-5 分钟 | ECS、ALB、Auto Scaling、IAM |
| 5. CDN 层 | ~3-5 分钟 | CloudFront |
| 6. AgentCore Web Search *(默认开，`us-east-1`)* | ~2-3 分钟 | AgentCore Gateway + Web Search target + service role + task role 授权 + LiteLLM MCP 注册 |
| 7. SearXNG MCP *(可选 `DEPLOY_SEARXNG=1`，需 Docker)* | ~5-8 分钟 | ECR 镜像、Fargate 服务、Cloud Map DNS、MCP 注册 |

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
| `claude-opus-5` | `us.anthropic.claude-opus-5` | **最强能力**，1M 上下文 / 128K 输出；adaptive thinking 默认开。拒绝 `temperature`/`top_p`/`top_k`，必须 drop |
| `claude-sonnet-4-6` | `us.anthropic.claude-sonnet-4-6` | **性价比最优，推荐** |
| `claude-haiku-4-5` | `us.anthropic.claude-haiku-4-5-20251001-v1:0` | 最快最便宜 |
| `gpt-5.6-sol` | `bedrock_mantle/openai.gpt-5.6-sol` | OpenAI 旗舰 — 前沿推理 + agentic（coding/安全/科研），走 Responses API。us-east-1 / us-east-2 |
| `gpt-5.6-terra` | `bedrock_mantle/openai.gpt-5.6-terra` | 均衡，约 Sol 一半成本。+ us-west-2 |
| `gpt-5.6-luna` | `bedrock_mantle/openai.gpt-5.6-luna` | 最快最便宜，高并发。+ us-west-2 |

> 所有 AWS Bedrock 模型（Claude **和** GPT-5.6）都走 ECS 任务角色 IAM 认证，**无需 API Key**。GPT-5.6 走 `bedrock-mantle` 端点（OpenAI Responses API），任务角色已带 `BedrockMantleAccess` 策略（见 `cfn/04-ecs.yaml`）。
> **区域说明**：Bedrock 模型 ID 用跨区推理配置文件前缀（`us.`），config 不硬编码区域，模型从注入的 `AWS_REGION_NAME` 继承部署区域。非美国区部署请改前缀（`eu.`/`apac.`）。GPT-5.6 Sol 仅 us-east-1/us-east-2，Terra 与 Luna 另加 us-west-2。

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
export ANTHROPIC_DEFAULT_OPUS_MODEL="claude-opus-4-8"
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
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-opus-4-8"
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
    "models": ["claude-opus-4-8", "claude-sonnet-4-6", "claude-haiku-4-5"]
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

**ECS 自动伸缩**已默认开启，基于 CPU 利用率自动扩缩容：

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `MinCapacity` | 2 | 最小 ECS 任务数 |
| `MaxCapacity` | 4 | 最大 ECS 任务数 |
| `CpuTargetValue` | 70 | 目标 CPU 利用率（%） |

扩容冷却：60 秒 · 缩容冷却：300 秒

调整自动伸缩参数：
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

手动临时调整副本数（Auto Scaling 会自动恢复）：
```bash
aws ecs update-service --cluster <PROJECT_NAME>-cluster --service <PROJECT_NAME>-service \
  --desired-count 4 --region <YOUR_REGION>
```

```bash
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

# 3. 按逆序删除堆栈（可选模块先删 —— cfn/08 给 ECS task role 挂了 policy，须在 ECS 栈之前删）
for stack in <PROJECT_NAME>-agentcore-websearch <PROJECT_NAME>-searxng-mcp <PROJECT_NAME>-cloudfront <PROJECT_NAME>-ecs <PROJECT_NAME>-data <PROJECT_NAME>-secrets <PROJECT_NAME>-vpc; do
  aws cloudformation delete-stack --stack-name $stack --region <YOUR_REGION> 2>/dev/null || true
  aws cloudformation wait stack-delete-complete --stack-name $stack --region <YOUR_REGION> 2>/dev/null || true
  echo "已删除: $stack"
done
```

---

## 成本估算（月）

| 组件 | 费用 (USD) | 说明 |
|------|-----------|------|
| Aurora Serverless v2 | $30–$150 | 空闲 ~$43 (0.5 ACU)；中等负载 ~$172 |
| ECS Fargate (2–4副本) | ~$50–$100 | 0.5 vCPU / 4GB × 2–4（Graviton，自动伸缩） |
| ElastiCache Valkey | ~$6 | Serverless (100MB min) |
| NAT Gateway | ~$35 | $0.045/hr + 流量 |
| CloudFront 等 | ~$10 | 按请求计费 |
| **基础设施合计** | **$140–$240** | 不含模型调用费 |

> 💰 相比原版 RDS db.m7g.large（仅数据库 ~$200/月），Aurora Serverless v2 在低负载时节省约 **70%** 数据库成本。

---

## 常见问题

### Q: 部署或删除时 S3 config 桶报 `s3:PutEncryptionConfiguration` 显式拒绝（SCP）

**根因**：账户在某 AWS Organization 下、其 SCP 拒绝了 `s3:PutEncryptionConfiguration`。`*-data` 栈的 `ConfigBucket` 带 `BucketEncryption` 属性，CloudFormation 创建/删除桶时会调 `PutBucketEncryption` → 403 显式拒绝，导致建栈失败、删栈也失败（`DELETE_FAILED`）。

**解决**：删掉 `cfn/03-data.yaml` 里 `ConfigBucket` 的 `BucketEncryption` 块即可（S3 自 2023-01 起默认 AES256 加密，桶仍然加密）。若栈已卡在 `DELETE_FAILED`，先清空桶的所有**版本**（桶开了 versioning，需对每个 version 和 delete marker 跑 `aws s3api delete-object --version-id ...`），再重试删栈。

### Q: `DEPLOY_SEARXNG=1` 时 SearXNG 镜像 build 报 base 镜像 `not found`

**根因**：上游 `searxng/searxng` 只保留滚动日期 tag（如 `2026.6.22-<sha>`）并定期清理旧 tag，所以 Dockerfile 里 pin 的旧 tag 可能从 Docker Hub 消失。

**解决**：把 `searxng-mcp/searxng/Dockerfile` 的 `FROM searxng/searxng:<tag>` 改成一个当前可用的 tag（`docker buildx imagetools inspect searxng/searxng:<tag>` 确认含 `linux/arm64`），或 pin 到不可变 digest `searxng/searxng@sha256:<digest>`。

### Q: 升级到 1.84+ 后，ECS task 启动后 child process 反复 die

**根因**：LiteLLM 1.80+ 在 `--num_workers >= 2` 时父进程 fork 出来的 worker 启动后立即崩溃且不输出 stderr，是 [BerriAI/litellm#18457](https://github.com/BerriAI/litellm/issues/18457) 的已知 bug。

**症状**：日志里只有 `INFO: Waiting for child process [N]` 和 `INFO: Child process [N] died` 反复刷，target group health check 失败。

**修复**：本仓库 `cfn/04-ecs.yaml` 启动命令已改为 `--num_workers 1`。如果 fork 别人版本，确保也是 1。0.5 vCPU × 单 worker 在常规负载下完全够用；担心 CPU 瓶颈可以提升 vCPU 到 1 而不是加 worker。

### Q: LiteLLM 镜像 tag 命名变了（1.84+）

**注意 tag 命名规则在 1.84 改了**：

| 版本 | tag 格式 | image 写法 |
|------|---------|------|
| ≤ 1.83.x | `v1.83.7-stable` | `ghcr.io/berriai/litellm:main-v1.83.7-stable` |
| ≥ 1.84.x | `v1.84.0` | `ghcr.io/berriai/litellm:v1.84.0`（**没有 main- 前缀，没有 -stable 后缀**）|

`deploy.sh` 已经做了适配，case 语句根据 tag 是否含 `-stable` 自动决定要不要拼 `main-` 前缀。

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
  -d '{"team_alias": "dev-team", "models": ["claude-sonnet-4-6", "claude-haiku-4-5", "claude-opus-4-8"]}'
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

### Q: 通过 CloudFront 调用 POST /v1/messages 偶发 504（OriginCommError）

**现象**：客户端用 Anthropic Messages API（`POST /v1/messages`）访问 `https://<YOUR_CLOUDFRONT_DOMAIN>` 时偶尔收到 504，且耗时正好 ~60 秒；但 ECS / LiteLLM 侧日志显示同一次请求 `200 OK`。CloudFront 访问日志里可以看到 `x-edge-detailed-result-type = OriginCommError`、`time-taken ≈ 60.1s`。

**根因**：默认情况下 ALB 的 `idle_timeout = 60s`、CloudFront 的 `OriginReadTimeout = 60s`，都会在 60 秒内"无字节传输"时主动 RST 连接。Claude 长上下文 / 非流式请求（尤其 Opus 或开启 extended thinking）TTFB 很容易超过 60 秒，于是被中间层切断，CloudFront 给客户端抛 504。

**修复（本次更新起已修复）**：
- `cfn/04-ecs.yaml` 设置 ALB `idle_timeout.timeout_seconds = 4000`（ALB 上限）。
- `cfn/05-cloudfront.yaml` 设置 `OriginReadTimeout = 120`（CloudFront 配额上限，可通过 Service Quotas 申请增加）、`OriginKeepaliveTimeout = 60`。

**对已部署的栈做一次性热修**（无需重建）：

```bash
# 1) 调高 ALB 空闲超时
aws elbv2 modify-load-balancer-attributes --region <YOUR_REGION> \
  --load-balancer-arn <ALB_ARN> \
  --attributes Key=idle_timeout.timeout_seconds,Value=4000

# 2) 调高 CloudFront 源站超时
aws cloudfront get-distribution-config --id <DIST_ID> > /tmp/cf.json
ETAG=$(jq -r .ETag /tmp/cf.json)
jq '.DistributionConfig
    | .Origins.Items[0].CustomOriginConfig.OriginReadTimeout = 120
    | .Origins.Items[0].CustomOriginConfig.OriginKeepaliveTimeout = 60' \
  /tmp/cf.json > /tmp/cf-new.json
aws cloudfront update-distribution --id <DIST_ID> --if-match "$ETAG" \
  --distribution-config file:///tmp/cf-new.json
```

**建议**：即使调大超时，客户端也强烈建议使用流式响应（`"stream": true`）。流式每秒都有 chunk 下行，ALB 的 idle 计时器永远不会触发，首 token 体验和 p99 延迟都会明显改善。

### Q: Claude Code / 新版 Anthropic 客户端报 `400 context_management: Extra inputs are not permitted`

**现象**：调用 `POST /v1/messages` 时带上了 `context_management` 字段（Claude Code 2.1.116+ 和部分新版 Anthropic SDK 会自动注入用于上下文压缩），服务端返回：

```
API Error: 400 {"error":{"message":"{\"message\":\"context_management: Extra inputs are not permitted\"}.
Received Model Group=claude-sonnet-4-6 ..."}}
```

**根因**：AWS Bedrock 的 Anthropic Invoke 接口目前（2026-04）不接受 `context_management` 字段。LiteLLM 在 `/v1/messages`（Anthropic 透传）路由上原样转发，Bedrock Pydantic 校验严格拒绝。注意：在 `litellm_settings` / `litellm_params` 里配的 `additional_drop_params: [context_management]` **只对 OpenAI 格式（`/v1/chat/completions`）路由生效，对 `/v1/messages` 不生效**。

**解决方案（已内置于本仓库）**：通过自定义 `CustomLogger` 的 `async_pre_call_hook`，在请求进入 Bedrock 前把 `context_management` 字段剥掉。实现位于 [`config/callbacks/bedrock_ctx_stripper.py`](config/callbacks/bedrock_ctx_stripper.py)，并在 `config/litellm-config.yaml` 里注册：

```yaml
litellm_settings:
  callbacks: ["bedrock_ctx_stripper.bedrock_ctx_stripper_instance"]
```

`deploy.sh` 会把 callback 文件和 `litellm-config.yaml` 一起上传到 S3；容器启动时（见 `cfn/04-ecs.yaml` 的 Command）会同时下载两份文件到 `/app/`，并导出 `PYTHONPATH=/app:${PYTHONPATH}` 让 LiteLLM 能 import 到模块。

**验证**：

```bash
# 修复前（失败）：
curl -X POST https://<CLOUDFRONT_DOMAIN>/v1/messages \
  -H "Authorization: Bearer <KEY>" -H "anthropic-version: 2023-06-01" \
  -d '{"model":"claude-sonnet-4-6","max_tokens":100,
       "messages":[{"role":"user","content":"hi"}],
       "context_management":{"edits":[{"type":"clear_tool_uses_20250919"}]}}'
# → 400 Extra inputs are not permitted

# 修复后（成功）：同样的请求返回 200 + 正常的 Anthropic response。
```

**什么时候可以删掉？** 等 Bedrock Invoke 原生支持 `context_management`（关注 LiteLLM main 分支的 Bedrock transformation 更新）。在那之前建议保留此 callback。

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
│   ├── 04-ecs.yaml              # ECS、ALB、Auto Scaling、IAM
│   └── 05-cloudfront.yaml       # CloudFront
│   ├── 07-searxng-mcp.yaml      # SearXNG MCP web search（可选，需 Docker）
│   └── 08-agentcore-websearch.yaml  # AgentCore 托管 web search（默认开，us-east-1）
├── config/
│   └── litellm-config.yaml      # 模型路由配置
├── scripts/
│   ├── sync-mcp-servers.sh           # 注册 Tavily + Exa MCP
│   ├── sync-searxng-mcp.sh           # 注册 SearXNG MCP
│   └── sync-agentcore-websearch.sh   # 注册 AgentCore Web Search MCP
├── deploy.sh                    # 一键部署脚本
├── README.md                    # English
└── README_CN.md                 # 中文指南
```
