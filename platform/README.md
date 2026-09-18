# T-POT Booking Platform（自助推理测试平台 / CDK Stack）

本目录是「一键自助 Spot GPU 推理测试环境」的**平台本体**：一个 AWS CDK（TypeScript）栈，加四个 Python Lambda 与一个 React/Vite 前端门户。控制面全部 Serverless，数据面是多区域 EC2 Spot GPU。

> 配套博客：[从 0 到推理：用 AWS Spot GPU 打造一键自助的短时推理测试环境](https://aws.amazon.com/cn/blogs/china/0-inference-aws-spot-gpu-inference-testing-environment/)
>
> 本仓库是一个基于 **MIT-0** 授权的 AWS sample，按「示例」提供，**不是**受支持的产品（provided as a sample, not a supported product）。
> This repository is an AWS sample licensed under MIT-0. It is provided as a sample, not a supported product.

本文所有部署说明均以本目录下的 CDK 代码（`lib/tpot-booking-stack.ts`、`bin/app.ts`）为准，不臆造脚本或行为。示例命令中的账号一律用占位符 `<YOUR_ACCOUNT_ID>`，请替换为你自己的账号 ID。

---

## 0. 组件概览

| 组件 | 内容 |
|---|---|
| Stack 名 | `TpotBookingStack` |
| 默认 Region | `us-east-1`（可通过 `-c region=...` 覆盖） |
| 前端 | React / Vite，构建产物 `frontend/dist` 上传到 S3，由 CloudFront 分发 |
| API | API Gateway REST（`TpotBookingApi`），经 CloudFront `/api/*` 行为转发；Lambda TokenAuthorizer 做 Basic Auth |
| Lambda | 四个 `python3.12`（`handler.handler`）：api / capacity-poller / deployer / orphan-cleaner |
| 数据 | DynamoDB（预约/通知配置/部署方案）+ SNS 通知主题 |
| 数据面 | 多区域（us-east-1 / us-east-2 / us-west-2）EC2 Spot GPU，SSM + docker compose 拉起 SGLang |

---

## 1. 前置条件

### 1.1 工具链

- 一个 AWS 账号，且本地/CloudShell 已配置好凭证。
- Node.js + npm（用于 CDK 与前端构建）。
- Python 3.12（Lambda 运行时；本地打包时 CDK 会用到）。
- AWS CDK CLI（`npm install -g aws-cdk`，或用本目录 `npx cdk`）。首次在某账号/区域使用需 `cdk bootstrap`。

### 1.2 必须由你自己预置的资源（Stack 不会创建）

以下资源栈只会**引用/查询**，不会替你创建，请务必提前手动准备好，否则部署或运行时会失败：

1. **SSM SecureString `/tpot-booking/basic-auth-credentials`** —— 门户与 API 的 Basic Auth 凭证。栈只用 `fromSecureStringParameterAttributes` 引用它，**不创建**。值的格式是 `username:password`：

   ```bash
   aws ssm put-parameter \
     --name /tpot-booking/basic-auth-credentials \
     --type SecureString \
     --value 'admin:CHANGE_ME_strong_password' \
     --region us-east-1
   ```

2. **安全组 `tpot-bench-noingress-sg`** —— capacity-poller 只对它做 `DescribeSecurityGroups`（按名字查 ID），**不创建**。请在**每个**目标区域（us-east-1 / us-east-2 / us-west-2）预置一个同名安全组（建议无入站规则，仅出站，实例通过 SSM 管理，无需开放端口）。

3. **各区域子网** —— poller 只做 `DescribeSubnets`，**不创建**。请确保三个目标区域都有可用子网（对应博客部署步骤里的「子网映射」）。

### 1.3 Stack 会替你创建的 IAM（无需手动建）

- IAM 角色 `tpot-bench-ec2-role` + 实例配置文件 `tpot-bench-ec2-profile`（附 `AmazonSSMManagedInstanceCore` 与对 `tpot-bench-scripts/*` 的 `s3:GetObject`）。EC2 实例启动时挂这个 profile，poller 用它的名字启动实例。

> 小结：**SSM 凭证参数、`tpot-bench-noingress-sg` 安全组、各区域子网**是你的前置作业；**EC2 role/instance profile** 由栈创建。

---

## 2. 构建前端

前端构建产物 `frontend/dist` 会被 CDK 的 BucketDeployment 上传到前端 S3 桶，因此**部署前必须先构建**：

```bash
cd frontend
npm install
npm run build      # 实际执行 tsc && vite build，产物在 frontend/dist
cd ..
```

前端调用 API 走相对路径 `/api/*`，由 CloudFront 的 `/api/*` 行为（含一个把 `/api` 改写成 `/<stage>` 的 CloudFront Function）转发到 API Gateway，因此**前端无需在构建期知道 API URL**。

---

## 3. CDK 部署

```bash
# 在 platform/ 目录
npm install

# 首次在该账号+区域使用 CDK 需 bootstrap
npx cdk bootstrap

# 部署（默认 Region us-east-1）
npx cdk deploy
```

### 3.1 覆盖 account / region / modelName

栈支持三个 context 覆盖：`account`、`region`、`modelName`。

```bash
# 显式指定账号与区域（推荐用环境变量或 -c，不要写死真实账号）
npx cdk deploy \
  -c account=<YOUR_ACCOUNT_ID> \
  -c region=us-east-1

# 也可用标准 CDK 环境变量
CDK_DEFAULT_ACCOUNT=<YOUR_ACCOUNT_ID> CDK_DEFAULT_REGION=us-east-1 npx cdk deploy

# 覆盖 deployer 的默认模型（默认 deepseek-ai/DeepSeek-V4-Flash）
npx cdk deploy -c modelName=deepseek-ai/DeepSeek-V4-Flash
```

> `package.json` 脚本：`build` = `tsc`，`cdk` = `cdk`。可用 `npm run cdk -- deploy ...` 代替 `npx cdk deploy ...`。

---

## 4. 部署产物（CfnOutputs）

`cdk deploy` 完成后会输出以下 8 个值：

| Output | 含义 |
|---|---|
| `ApiUrl` | API Gateway 的 stage URL（前端已通过 CloudFront `/api/*` 转发，通常无需直连） |
| `CloudFrontDomain` | **门户入口**：用浏览器打开这个域名即可访问自助门户 |
| `BookingTableName` | 预约表 `TpotBookingTable`（pk `bookingId`，GSI `instanceType-status-index`） |
| `NotificationConfigTableName` | 通知配置表 `TpotNotificationConfigTable`（pk `configId`） |
| `DeploymentPlanTableName` | 部署方案表 `TpotDeploymentPlanTable`（pk `planId`） |
| `NotificationTopicArn` | SNS 通知主题 `TpotBookingNotifications` |
| `FrontendBucketName` | 前端 S3 桶 `tpot-booking-frontend-<account>-<region>` |
| `ComposeBucketName` | compose S3 桶 `tpot-booking-compose-<account>-<region>`（由 `lambda/deployer/compose-files` 同步而来） |

拿门户地址的快捷命令：

```bash
aws cloudformation describe-stacks \
  --stack-name TpotBookingStack \
  --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDomain'].OutputValue" \
  --output text
```

---

## 5. 配置飞书（Lark）Webhook

每次关键状态变更都会推送到飞书。配置方式二选一：

- **门户内**：打开门户的「通知设置 / Settings」页面填入飞书机器人 webhook，并可点「测试」验证连通。
- **API**：

  ```bash
  # 新建/更新通知配置
  POST /api/notifications
  PUT  /api/notifications

  # 发送一条测试消息，确认 webhook 可达
  POST /api/notifications/test-webhook
  ```

底层由 SNS 主题 `TpotBookingNotifications` + Lambda 负责投递。

---

## 6. 预约 / 释放流程

1. 打开门户（CloudFront 域名），进入 **BookingPage / 预约页**。
2. 选择**机型**（H200 / B300）、**部署方案**（docker-compose 方案，见第 7 节）、填入**访问白名单 IP**，一键提交。
3. 平台随后：
   - **capacity-poller**（EventBridge 每 1 分钟触发）在 us-east-1 / us-east-2 / us-west-2 扫描 Spot 容量，抢到即用 `tpot-bench-ec2-profile` 启动实例；
   - **deployer**（`check_progress` 每 2 分钟触发，超时 10 分钟）经 SSM 在实例上用 `docker compose` 拉起 SGLang 拓扑并做健康检查，就绪后把推理 endpoint + 飞书通知一并推送；
   - 状态与历史全部落 DynamoDB，门户 **History 页**可查。
4. **释放**：门户上点释放/终止，或调用 `DELETE /api/bookings/{bookingId}`。
5. **兜底**：**orphan-cleaner**（EventBridge 每 15 分钟触发）回收游离/超时实例，避免「开了忘关」。

> 并发上限：H200 与 B300 各同时最多 **1** 台，从源头避免同机型重复拉起。

---

## 7. 部署方案（docker-compose）与自定义上传

每个部署方案用一个 docker-compose 文件描述完整推理拓扑（模型路径、tp、mem-fraction-static、CUDA Graph 批大小、EAGLE 投机解码、PD 分离等）。deployer 运行时**优先**从 compose S3 桶读取，读取失败才回退到 Lambda 自带的 bundle。

内置 compose 文件与部署方案 id 的对应关系（下表依据 `lambda/deployer/compose-files/` 目录中**实际存在**的 compose 文件整理，并与 [docs/UPDATE-COMPOSE.md](./docs/UPDATE-COMPOSE.md) 交叉核对；如与该文档的示例列表有出入，以本目录实际文件为准）：

| 部署方案 id | compose 文件 |
|---|---|
| `h200-tp8-eagle` | `docker-compose-tp8-h200.yaml` |
| `h200-tp8-eagle-0731` | `docker-compose-tp8-h200-0731.yaml` |
| `b300-tp8-eagle` | `docker-compose-tp8-b300.yaml` |
| `b300-tp8-eagle-0731` | `docker-compose-tp8-b300-0731.yaml` |
| `b300-pd-2p2d` | `docker-compose-pd-2p2d.yaml` |
| `b300-pd-3p1d` | `docker-compose-pd-v4flash-b300.yaml` |
| `b300-tp8-eagle-0731-nodspark` | `docker-compose-tp8-b300-0731-nodspark.yaml` |

> 说明：上表中的部署方案 id 是**文档约定**（便于沟通与查阅），并非由代码强制校验 —— Lambda/前端里没有 id↔compose 文件的硬映射，真正生效的是实际存在的 compose 文件。

**门户「方案管理」页自定义上传**：填写「方案名」、选择「机型」、上传一个 `.yaml` compose 模板即可新增方案（记录写入 `TpotDeploymentPlanTable`）。上传后**重新部署**才会生效。

> 注意：`modelName` 现在会**从 compose yaml 中自动解析**（读取 `--model-path`），无需再单独填写，新模型上传即可直接部署（此前需要手填、易错，已修复）。

**只更新 compose、不跑 `cdk deploy`**：可以直接改 compose S3 桶里的 yaml，下一次部署即生效。完整操作手册见 [docs/UPDATE-COMPOSE.md](./docs/UPDATE-COMPOSE.md)。注意 `cdk deploy` 会用 `lambda/deployer/compose-files/` 重新覆盖 S3 内容。

---

## 8. API 路由一览

所有方法都经 `TokenAuthorizer` 做 Basic Auth（凭证来自 SSM SecureString `/tpot-booking/basic-auth-credentials`）。

| 资源 | 方法 | 说明 |
|---|---|---|
| `/bookings` | `GET` / `POST` | 列出 / 新建预约 |
| `/bookings/{bookingId}` | `GET` / `PUT` / `DELETE` | 查询 / 更新 / 释放单个预约 |
| `/notifications` | `GET` / `POST` / `PUT` | 通知配置的读取与增改 |
| `/notifications/test-webhook` | `POST` | 发送一条测试通知 |
| `/status` | `GET` | 各区域容量 / 平台状态 |
| `/deployment-plans` | `GET` / `POST` | 列出 / 新建部署方案（含自定义上传） |
| `/deployment-plans/{planId}` | `DELETE` | 删除部署方案 |

---

## 9. Lambda 与定时器

| Lambda | 运行时 / 超时 | 关键环境变量 | EventBridge |
|---|---|---|---|
| `tpot-booking-api-handler` | python3.12 / 30s | — | API Gateway 触发 |
| `tpot-booking-capacity-poller` | python3.12 / 5min | `REGIONS=us-east-1,us-east-2,us-west-2`、`INSTANCE_PROFILE=tpot-bench-ec2-profile`、`SECURITY_GROUP=tpot-bench-noingress-sg` | 每 1 分钟 |
| `tpot-booking-deployer` | python3.12 / 10min | `MODEL_NAME`（默认 `deepseek-ai/DeepSeek-V4-Flash`，可用 `-c modelName` 覆盖） | `check_progress` 每 2 分钟 |
| `tpot-booking-orphan-cleaner` | python3.12 / 5min | `REGIONS`（同上） | 每 15 分钟 |

---

## 10. 相关文档

- 更新 compose 而不 `cdk deploy`：[docs/UPDATE-COMPOSE.md](./docs/UPDATE-COMPOSE.md)
- 项目总览与选型方法论：[../README.md](../README.md)、[../docs/benchmark-methodology.md](../docs/benchmark-methodology.md)
- 授权：仓库根 [../LICENSE](../LICENSE)（MIT-0）
