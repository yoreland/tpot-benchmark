# B300 Live Instance - 测试环境信息

> **状态**: RUNNING (截至 2026-08-09 15:58 UTC)
> **只读监控用** - 不要通过此文档修改任何实例配置

---

## 实例信息

| 项 | 值 |
|---|---|
| Instance ID | `i-0d2500b8c91851a30` |
| 类型 | `p6-b300.48xlarge` (8x NVIDIA B300 288GB HBM3e) |
| Region / AZ | us-west-2 / us-west-2b |
| 启动时间 | 2026-08-09 08:32:29 UTC |
| Spot 请求 | `sir-dzrfki2p`, one-time, max $60/hr |
| 现价 | ~$50/hr |
| 安全组 | `sg-0e24f30107d9a84c3` (tpot-bench-noingress-sg, 无 ingress) |
| IAM Profile | `tpot-bench-ec2-profile` (SSM + S3 write) |
| 自终止 | **关闭** (SELF_TERMINATE=false, 无看门狗) |

## 访问方式

```bash
# SSM session (交互式 shell)
aws ssm start-session --target i-0d2500b8c91851a30 --region us-west-2

# SSM 发命令 (非交互)
aws ssm send-command \
  --region us-west-2 \
  --instance-ids i-0d2500b8c91851a30 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["date -u","docker ps","nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader"]' \
  --timeout-seconds 30 --query 'Command.CommandId' --output text

# 然后查结果
aws ssm get-command-invocation --region us-west-2 \
  --command-id <COMMAND_ID> --instance-id i-0d2500b8c91851a30 \
  --query 'StandardOutputContent' --output text
```

## 当前配置 (2026-08-09 14:35 UTC 启动)

```bash
docker run -d --name sglang-server --gpus all --ipc=host --net=host --shm-size=64g \
  -v /opt/dlami/nvme:/opt/dlami/nvme \
  -e SGLANG_OPT_DEEPGEMM_MEGA_MOE_NUM_MAX_TOKENS_PER_RANK=8320 \
  lmsysorg/sglang:v0.5.12.post1-cu130 \
  python3 -m sglang.launch_server \
    --model-path /opt/dlami/nvme/models/deepseek-ai__DeepSeek-V4-Flash \
    --tp 8 \
    --moe-a2a-backend megamoe \
    --mem-fraction-static 0.85 \
    --trust-remote-code \
    --host 0.0.0.0 --port 30000 \
    --cuda-graph-max-bs 64 \
    --speculative-algorithm EAGLE \
    --speculative-num-steps 3 \
    --speculative-eagle-topk 1 \
    --speculative-num-draft-tokens 4 \
    --enable-metrics
```

## 监控命令

```bash
# 快速状态检查
aws ssm send-command --region us-west-2 --instance-ids i-0d2500b8c91851a30 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["date -u","docker ps --format \"{{.Names}} {{.Status}}\"","curl -s -m 3 http://127.0.0.1:30000/health && echo READY || echo NOT_READY","nvidia-smi --query-gpu=index,utilization.gpu,memory.used --format=csv,noheader"]' \
  --timeout-seconds 30 --query 'Command.CommandId' --output text

# SGLang 日志最新 20 行
aws ssm send-command --region us-west-2 --instance-ids i-0d2500b8c91851a30 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["docker logs --tail 20 sglang-server 2>&1"]' \
  --timeout-seconds 30 --query 'Command.CommandId' --output text

# 实例是否还活着
aws ec2 describe-instances --region us-west-2 --instance-ids i-0d2500b8c91851a30 \
  --query 'Reservations[].Instances[].State.Name' --output text
```

## Benchmark 命令 (服务就绪后执行)

```bash
# 客户验收 (40K input / 1.5K output)
aws ssm send-command --region us-west-2 --instance-ids i-0d2500b8c91851a30 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["docker exec sglang-server python3 -m sglang.bench_serving --backend sglang --dataset-name random --num-prompts 50 --max-concurrency 1 --random-input 40000 --random-output 1500 --output-file /opt/dlami/nvme/results/b300_tp8_eagle_custom.json 2>&1","aws s3 cp /opt/dlami/nvme/results/b300_tp8_eagle_custom.json s3://tpot-bench-results-077090643075-us-west-2/runs/b300-tp8-eagle/bench_custom.json --region us-west-2"]' \
  --timeout-seconds 600 --query 'Command.CommandId' --output text

# LMSYS 基线对标 (30K input / 4096 output)
aws ssm send-command --region us-west-2 --instance-ids i-0d2500b8c91851a30 \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["docker exec sglang-server python3 -m sglang.bench_serving --backend sglang --dataset-name random --num-prompts 50 --max-concurrency 1 --random-input 30000 --random-output 4096 --output-file /opt/dlami/nvme/results/b300_tp8_eagle_official.json 2>&1","aws s3 cp /opt/dlami/nvme/results/b300_tp8_eagle_official.json s3://tpot-bench-results-077090643075-us-west-2/runs/b300-tp8-eagle/bench_official.json --region us-west-2"]' \
  --timeout-seconds 900 --query 'Command.CommandId' --output text
```

## 测试矩阵 (在此实例上逐个跑)

| # | 配置 | Docker 参数差异 | 目的 |
|---|---|---|---|
| 1 | tp=8 + EAGLE + megamoe | *(当前)* | 第一组 B300 数字 |
| 2 | tp=8 + megamoe (无 EAGLE) | 去掉 `--speculative-*` 四个参数 | 量化 EAGLE 收益 |
| 3 | tp=4 + EAGLE + megamoe | 改 `--tp 4` | 对标 H200 的 tp=4 |
| 4 | tp=8 + EAGLE, 不指定 moe backend | 去掉 `--moe-a2a-backend megamoe` | 对比 megamoe vs auto |

每次切换配置:
```bash
docker rm -f sglang-server
# 然后用新参数 docker run (上面模板改参数即可)
# 权重在 NVMe 上不需要重下
```

## 结果存储

```
s3://tpot-bench-results-077090643075-us-west-2/runs/
  b300-tp8-eagle/          # 配置 1
  b300-tp8-no-eagle/       # 配置 2
  b300-tp4-eagle/          # 配置 3
  b300-tp8-eagle-auto-moe/ # 配置 4
```

## 已知踩坑 (不要重复)

1. **`--enable-dp-attention` + `--dp N` 在单进程下会死**: `AssertionError: short-circuiting allreduce will lead to hangs`, GPU 清零
2. **`tp_size % dp_size` 必须为 0**: tp=2 dp=4 直接 assert 失败
3. **B200 的 triton MoE 有 padding bug**: 不要在 B300 上试 triton 以外的理由去测 B200 理论
4. **冷启动约 10-20 分钟**: DeepGEMM JIT compile + CUDA graph capture

## 紧急情况

```bash
# 如果需要手动终止
aws ec2 terminate-instances --instance-ids i-0d2500b8c91851a30 --region us-west-2
```
