# 更新 Compose 文件操作手册

本文档说明如何通过 AWS CloudShell 直接更新 S3 中的 compose 文件，无需执行 `cdk deploy`。

## 原理

Deployer Lambda 在运行时按以下优先级加载 compose 文件：

1. **S3 桶** (优先) - 从 `s3://<compose-bucket>/compose-files/` 读取
2. **本地 bundle** (回退) - 使用 Lambda 打包时自带的 compose 文件

因此，只需更新 S3 中的 yaml 文件，下一次部署即会使用新配置。

## 前提条件

- 已部署 CDK Stack（首次部署会自动创建 S3 桶并上传初始 compose 文件）
- 拥有 AWS CloudShell 访问权限，或本地安装了 AWS CLI

## 步骤

### 1. 确认 Compose 桶名

从 CDK 输出中获取桶名：

```bash
aws cloudformation describe-stacks \
  --stack-name TpotBookingStack \
  --query "Stacks[0].Outputs[?OutputKey=='ComposeBucketName'].OutputValue" \
  --output text
```

或者设置环境变量方便后续操作：

```bash
COMPOSE_BUCKET=$(aws cloudformation describe-stacks \
  --stack-name TpotBookingStack \
  --query "Stacks[0].Outputs[?OutputKey=='ComposeBucketName'].OutputValue" \
  --output text)
echo "Compose bucket: $COMPOSE_BUCKET"
```

### 2. 查看当前 compose 文件列表

```bash
aws s3 ls s3://$COMPOSE_BUCKET/compose-files/
```

### 3. 下载文件进行编辑

```bash
# 下载单个文件
aws s3 cp s3://$COMPOSE_BUCKET/compose-files/docker-compose-tp8-h200.yaml .

# 下载全部文件到本地目录
aws s3 cp s3://$COMPOSE_BUCKET/compose-files/ ./compose-files/ --recursive
```

### 4. 编辑文件

在 CloudShell 中使用 `vi` 或 `nano` 编辑：

```bash
vi docker-compose-tp8-h200.yaml
```

### 5. 上传修改后的文件

```bash
# 上传单个文件
aws s3 cp docker-compose-tp8-h200.yaml s3://$COMPOSE_BUCKET/compose-files/

# 上传整个目录
aws s3 cp ./compose-files/ s3://$COMPOSE_BUCKET/compose-files/ --recursive
```

### 6. 通过 UI 触发生效

上传完成后，新的 compose 配置会在下一次部署时自动生效。操作方式：

1. 打开 T-POT Booking 管理页面
2. 选择目标预约，点击「切换方案」或「重新部署」
3. Deployer Lambda 会从 S3 拉取最新的 compose 文件进行部署

> 注意：已经运行中的实例不会自动更新，需要通过 UI 触发重新部署。

## 常见操作示例

### 添加 reasoning-parser 参数

编辑对应的 compose 文件，在 sglang 启动命令中添加：

```yaml
command: >
  python3 -m sglang.launch_server
  --model-path /models/deepseek-ai__DeepSeek-V4-Flash
  --tp 8
  --reasoning-parser deepseek-r1
  ...
```

### 调整 mem-fraction-static

```yaml
command: >
  python3 -m sglang.launch_server
  --model-path /models/deepseek-ai__DeepSeek-V4-Flash
  --tp 8
  --mem-fraction-static 0.88
  ...
```

### 添加 tool-call-parser

```yaml
command: >
  python3 -m sglang.launch_server
  --model-path /models/deepseek-ai__DeepSeek-V4-Flash
  --tp 8
  --tool-call-parser deepseek
  ...
```

## 注意事项

1. **S3 优先级高于本地 bundle** - 如果 S3 中存在对应文件，Lambda 会使用 S3 版本；S3 读取失败时才回退到本地 bundle。

2. **`cdk deploy` 会覆盖 S3 内容** - 每次执行 `cdk deploy` 时，BucketDeployment 会将 `lambda/deployer/compose-files/` 目录重新同步到 S3，覆盖之前通过 CloudShell 所做的修改。如果希望保留手动修改，请先同步回代码仓库。

3. **文件名必须匹配** - 上传的文件名必须与部署方案对应的 compose 文件名一致：
   - `h200-tp8-eagle` -> `docker-compose-tp8-h200.yaml`
   - `h200-tp8-eagle-0731` -> `docker-compose-tp8-h200-0731.yaml`
   - `b300-tp8-eagle` -> `docker-compose-tp8-b300.yaml`
   - `b300-tp8-eagle-0731` -> `docker-compose-tp8-b300-0731.yaml`
   - `b300-pd-2p2d` -> `docker-compose-pd-2p2d.yaml`
   - `b300-pd-2p2d-0731` -> `docker-compose-pd-2p2d-0731.yaml`
   - `b300-pd-3p1d` -> `docker-compose-pd-v4flash-b300.yaml`
   - `b300-pd-3p1d-0731` -> `docker-compose-pd-v4flash-b300-0731.yaml`

4. **验证 yaml 格式** - 上传前建议验证 yaml 格式正确：
   ```bash
   python3 -c "import yaml; yaml.safe_load(open('docker-compose-tp8-h200.yaml'))"
   ```

5. **查看部署日志** - 如果部署失败，可查看实例上的日志：
   ```bash
   # 通过 SSM Session Manager 连接实例后
   cat /var/log/tpot-bench/deploy.log
   ```
