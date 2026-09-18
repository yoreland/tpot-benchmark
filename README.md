# 从 0 到推理：AWS Spot GPU 一键自助推理测试环境

> 在浏览器里点一下，就能在 Spot GPU 实例（H200 / B300）上拉起一套 SGLang 推理服务，跑完测试、收到飞书（Lark）通知，用完即拆。面向不熟悉 AWS、又需要频繁做模型选型与性能验证的团队。

📖 配套博客：[从 0 到推理：用 AWS Spot GPU 打造一键自助的短时推理测试环境](https://aws.amazon.com/cn/blogs/china/0-inference-aws-spot-gpu-inference-testing-environment/)

> **授权说明**：本仓库是一个基于 **MIT-0（MIT No Attribution）** 授权的 AWS sample，按「示例」提供，**不是**受支持的产品。详见 [LICENSE](./LICENSE)。
>
> This repository is an AWS sample licensed under MIT-0. It is provided as a sample, not a supported product.

---

## 这是什么 / 解决什么痛点

团队在正式采购或大规模投入 GPU 前，通常要先做一轮选型验证：把候选模型在目标机型上真实跑起来，测性能、比效果、给结论。缺少现成工具时，这件事反复撞上同样的三堵墙。本方案用三条主线各破一堵：

| 痛点 | 解决主线 |
|---|---|
| **GPU 资源紧缺，测试却是短时、临时的**（一次约 2 小时，却要为 Capacity Block 等上一天） | **Spot 容量 + 容量轮询器（poller）**：不排队等预留，每分钟扫描各区域/可用区，一有容量立即抢占启动 |
| **业务 / LOB 用户不熟悉 AWS，走中台工单又慢** | **React 自助门户**：内置登录与授权，选机型 + 选方案、点一次即可，全程无需 AWS 账号或控制台 |
| **反复试验需要留痕与审计** | **DynamoDB 记录 + 站内 History 页 + 飞书（Lark）通知**：每次预约与状态变更持久化、可追溯 |

流程很直接：用户在门户里选好机型与部署方案、填入访问白名单 IP，一键提交；平台随即抢占 Spot GPU 容量、启动实例并部署 SGLang，就绪后把 endpoint 与飞书通知一并推送；用完点一下释放，成本随之停止。

---

## 架构总览

平台是一个 **AWS CDK 栈**，控制面全部 **Serverless**，数据面是**多区域 EC2 Spot GPU**：

- **控制面**：前端（React / Vite）托管在 S3、由 CloudFront 分发；API 经 CloudFront `/api/*` 行为转发到 API Gateway，由 Lambda 授权器做 Basic Auth；四个 Python Lambda 由 EventBridge 定时器协调；预约与状态全部落在 DynamoDB。
- **数据面**：多区域（`us-east-1` / `us-east-2` / `us-west-2`）EC2 Spot GPU。poller 抢到容量即启动实例，deployer 经 SSM 用 `docker compose` 在实例上拉起 SGLang 拓扑并做健康检查，orphan-cleaner 定时回收游离实例兜底成本。

四个 Python Lambda（`python3.12`，`handler.handler`）及其协调方式：

| Lambda | 职责 | 触发 / 节奏 |
|---|---|---|
| `tpot-booking-api-handler` | 门户 API（预约、通知配置、状态、部署方案） | API Gateway 请求（超时 30s） |
| `tpot-booking-capacity-poller` | 扫描各区域 Spot 容量，抢到即启动实例 | EventBridge 每 **1 分钟** |
| `tpot-booking-deployer` | 经 SSM + docker compose 部署 SGLang 并健康检查 | `check_progress` 每 **2 分钟**（超时 10min） |
| `tpot-booking-orphan-cleaner` | 回收游离 / 超时实例，兜底成本 | EventBridge 每 **15 分钟** |

数据流：`门户下单 → DynamoDB 记录 → poller 抢 Spot 容量 → deployer 部署 SGLang → 就绪推送 endpoint + 飞书通知 → 用完释放 / orphan-cleaner 兜底回收`。

> 说明：本仓库未内置架构图资源，架构以上文文字 + 表格描述为准；直观示意见配套博客。

---

## 快速开始 / 部署

完整、权威的部署步骤见 **[platform/README.md](./platform/README.md)**。这里只给最短路径：

1. **前置条件**：AWS 账号 + `cdk bootstrap`；Node/npm；Python 3.12。自行预置 SSM SecureString `/tpot-booking/basic-auth-credentials`（值 `username:password`）、安全组 `tpot-bench-noingress-sg` 以及三个区域的子网（这些**不由栈创建**；栈会创建 EC2 role/instance profile）。
2. **构建前端**：`cd platform/frontend && npm install && npm run build`（产物 `frontend/dist` 由 CDK 上传）。
3. **部署**：`cd platform && npm install && npx cdk deploy`（默认 `us-east-1`，可用 `-c account=<YOUR_ACCOUNT_ID> -c region=... -c modelName=...` 覆盖）。
4. **配飞书**：在门户「通知设置」页填 webhook，或用 `POST/PUT /api/notifications` + `POST /api/notifications/test-webhook`。
5. **预约 / 释放**：打开 CloudFront 域名（门户入口），选机型 + 方案 + 白名单 IP 一键预约；释放走门户或 `DELETE /api/bookings/{bookingId}`。

---

## 部署方案与自定义上传

每个部署方案用一个 **docker-compose 文件**描述完整推理拓扑（模型路径、tp、mem-fraction-static、CUDA Graph 批大小、EAGLE 投机解码、PD 分离等），改一行、重启一次即可验证一组新参数，不用动平台代码。

- **内置方案**：仓库自带多套开箱即用的 compose（H200 / B300 的 tp8-EAGLE、0731 权重变体、PD 2P2D / 3P1D 等），方案 id ↔ 文件名对应表见 [platform/docs/UPDATE-COMPOSE.md](./platform/docs/UPDATE-COMPOSE.md)。
- **自定义上传**：门户「方案管理」页填「方案名」+ 选「机型」+ 传一个 `.yaml`，即可新增方案；**重新部署后生效**。
- **`modelName` 现在会从 compose yaml 中自动解析**（读取 `--model-path`），无需再单独填写，上传新模型即可直接部署。

只想更新 compose、不想跑 `cdk deploy`？直接改 compose S3 桶里的 yaml，下次部署即生效，手册见 [platform/docs/UPDATE-COMPOSE.md](./platform/docs/UPDATE-COMPOSE.md)。

---

## 为什么用 Spot

AWS 上获取 GPU 算力主要有三种，各有取舍：

| 方式 | 特点 | 对本场景 |
|---|---|---|
| **Spot（竞价）** | 用 EC2 闲置容量，价格远低于按需、随开随用、无最短持有期，代价是可能被中断 | ✅ **最合适** |
| Capacity Block（容量块预留） | 容量有保障，但通常要提前约、往往等到次日甚至更久 | ❌ 为 2 小时等一天不划算 |
| ODCR（按需容量预留） | 「要用时一定有」，但只要预留存在就持续计费 | ❌ 短时任务偏贵 |

本方案的场景是一次只跑约 2 小时、可容忍中断的临时测试：**Spot 随开随用、成本最低**。配合 poller 每分钟抢容量、失败自动回收，恰好把「短、临时、高频」的选型验证做成低成本快速路径。

---

## 成本与三重防护

P5 / P6 这类 GPU 实例很烧钱，**一台每小时数十美元**（B300 约 $142/hr，B200 约 $114/hr）。方案在设计时就重点防浪费，内置三重防护，避免「开了忘关」：

1. **并发上限**：H200 与 B300 各同时最多 **1** 台，从源头避免同机型重复拉起、多台并存。
2. **飞书提醒**：每一次关键状态变更（抢到容量、部署就绪、失败、释放等）都推送到飞书，产品内和聊天侧都可追溯。
3. **超时自动清理**：部署超时 / 空闲超时会触发清理，`tpot-booking-orphan-cleaner` 每 15 分钟兜底回收游离实例。

> ⚠️ 即便有防护，也请对 P5 / P6 的燃烧率保持警惕：每小时数十美元意味着忘关一夜就是可观的账单。

---

## 仓库结构导航

| 目录 | 内容 |
|---|---|
| [`platform/`](./platform/) | **平台本体**（CDK sample）：CDK 栈、四个 Python Lambda、React/Vite 前端、内置 compose 方案。部署看 [platform/README.md](./platform/README.md) |
| [`reports/`](./reports/) | **真实实测数据**：四份 benchmark 报告，每份含自己的 README |
| `scripts/` + `infra/` | 更早的**裸 EC2 / EKS** benchmark 路线（分级台阶脚本、recipes、EKS/HyperPod 部署） |
| [`docs/`](./docs/) | 运维与复盘：[RUNBOOK.md](./docs/RUNBOOK.md)、[postmortem-2026-08-07-p5en-run.md](./docs/postmortem-2026-08-07-p5en-run.md)、b300-live-instance.md、run-summaries/，以及迁移来的[选型方法论深度文档](./docs/benchmark-methodology.md) |

---

## 实测数据 / 选型方法论

### Benchmark Reports

| 日期 | 硬件 | 配置 | TPOT P50 | Output tok/s | 结果 | 报告 |
|------|------|------|----------|-------------|------|------|
| 2026-08-09 | H200 x4 (p5en.48xlarge) | tp=4, EAGLE 3/1/4, Marlin | 3.330 ms | 224.2 (custom) / 282.5 (official) | **PASS** | [reports/h200-tp4-eagle-20260809](reports/h200-tp4-eagle-20260809/) |
| 2026-08-09 | B300 x8 (p6-b300.48xlarge) | tp=8, EAGLE 3/1/4, megamoe | 3.337 ms | 191.5 (custom) / 281.7 (official) | **PASS** | [reports/b300-tp8-eagle-20260809](reports/b300-tp8-eagle-20260809/) |
| 2026-08-10 | H200 x4 (p5en.48xlarge) | tp=4, EAGLE 3/1/4, Marlin — **并发扫描** 8K/1.5K c=1~32 | 3.256 ms (c=1) → 8.072 ms (c=32) | 286.2 (c=1) → 2,090.4 (c=32)，扩展 7.31x | **PASS** | [reports/h200-tp4-eagle-20260809 §5](reports/h200-tp4-eagle-20260809/#5-并发扫描-concurrency-sweep) |

> 并发扫描的核心结论：8K/1.5K 负载下，H200 tp=4 守住 TPOT P50 ≤ 4.5 ms 的并发上限是 **2**；
> 并发开到 32 可换 7.31x 吞吐，代价是 TPOT P50 升到 8.07 ms。
> B300 的现有扫描跑在旧版 SGLang (0.5.12.post1) 上，**不能与之做定量硬件对比**，
> 原因见 [B300 报告 5.2](reports/b300-tp8-eagle-20260809/#52-已补上的-h200-对比以及本节数据的两个已知问题)。

### 四份实测报告

- [reports/h200-tp4-eagle-20260809/](reports/h200-tp4-eagle-20260809/) —— H200 tp=4 EAGLE 基线 + 并发扫描
- [reports/b300-tp8-eagle-20260809/](reports/b300-tp8-eagle-20260809/) —— B300 tp=8 EAGLE 基线
- [reports/b300-h200-luna-sweep-20260810/](reports/b300-h200-luna-sweep-20260810/) —— B300 / H200 Luna 扫描
- [reports/b300-pd-customer-validation-20260810/](reports/b300-pd-customer-validation-20260810/) —— B300 PD 分离客户验收验证

### 选型方法论（深度技术文档）

最初的完整选型工作文档（TL;DR、场景与负载、投机解码、拓扑对比、硬件候选、测试矩阵、待确认问题、POC、权威信息源、不确定性声明、客户验收标准/结果矩阵/Spot 启动策略）已迁移至：

➡️ **[docs/benchmark-methodology.md](./docs/benchmark-methodology.md)**

---

## License

本项目基于 **MIT-0（MIT No Attribution）** 授权，见 [LICENSE](./LICENSE)。

本仓库是一个 AWS sample，按「示例」提供，**不是**受支持的产品。
This repository is an AWS sample licensed under MIT-0. It is provided as a sample, not a supported product.
