---
name: tpot-deployment-troubleshooter
description: >-
  Diagnose tpot GPU booking platform deployment failures. Read-only
  troubleshooting of booking status, SSM live and historical logs, the
  tpot-booking-deployer Lambda logs, and plan-vs-compose model mismatches.
  Use when a tpot booking is stuck or failed, when someone reports a
  "deployment failed" / "部署失败", or when investigating the deployer.
  Trigger keywords: tpot, booking, deployment failed, 部署失败, deployer,
  SGLang, PD, compose, deploy.log, model mismatch, NVMe RAID.
---

# tpot Deployment Troubleshooter (READ-ONLY)

## What this skill does

This skill packages a **read-only diagnostic workflow** for investigating why a
deployment on the **tpot GPU booking platform** failed or got stuck. It helps you
inspect booking records, SSM RunCommand history and live instance logs, the
`tpot-booking-deployer` Lambda logs, and mismatches between a DynamoDB deployment
plan and the compose file that actually runs on the instance.

> **⚠️ READ-ONLY SCOPE.** This skill performs **diagnosis only. It never makes any
> change.** It does not modify DynamoDB, does not update Lambda code, does not
> delete or mutate bookings, and only issues **read-only** commands over SSM
> (`tail`, `docker ps`, `docker logs`, `ls`, `df -h`, `cat`, `nvidia-smi`). Any
> remediation is left to a human operator, to be performed manually based on the
> conclusions this skill helps you reach. The scripts here will never fix anything
> for you on purpose.

## Prerequisites

Before running any script:

1. **Export AWS credentials to your environment** (the scripts read them directly;
   they never store or manage credentials):

   ```bash
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   export AWS_SESSION_TOKEN=...        # if using temporary credentials
   ```

   The credentials must be for the **customer AWS account** that hosts the
   `TpotBookingStack*` CDK stacks, in region **us-west-2** (default).

2. **Export the booking REST API Basic Auth** used by the CloudFront endpoint.
   The password is **never** written to any file; scripts read it from the
   environment:

   ```bash
   export TPOT_API_AUTH='username:password'
   ```

3. Optionally review / edit `scripts/config.env` for platform-specific defaults
   (region, API base URL, table names, Lambda name, log group, log paths, compose
   bucket). Every script does `source ../config.env` (relative to `scripts/`).

## Platform facts (context)

- Deployment platform is a set of CDK stacks (`TpotBookingStack*`) in the customer
  account, primarily **us-west-2**.
- Booking REST API is served through CloudFront:
  `https://d2z5rc3gcx01u5.cloudfront.net/api/bookings`
  (`GET` for the list, `GET /{bookingId}` for one). Requires HTTP Basic Auth via
  header `Authorization: Basic $(printf '%s' "$TPOT_API_AUTH" | base64)`.
- Booking record fields: `bookingId`, `status` (one of
  `polling / launching / deploying / ready / failed / terminated`),
  `deploymentPlan`, `instanceId`, `az`, `region`, `ssmCommandId`, `endpoint`.
- Components (all in the customer account, us-west-2):
  - Lambda `tpot-booking-deployer` (Phase 1 deployment orchestration). Env includes
    `MODEL_NAME`, `DEPLOYMENT_PLAN_TABLE=TpotDeploymentPlanTable`,
    `COMPOSE_BUCKET=tpot-booking-compose-<acct>-us-west-2`,
    `BOOKING_TABLE=TpotBookingTable`. Log group
    `/aws/lambda/tpot-booking-deployer` (siblings: `-capacity-poller`,
    `-api-handler`, `-orphan-cleaner`).
  - DynamoDB `TpotDeploymentPlanTable` (key `planId`; fields include `modelName`,
    `composeFile`, `instanceType`, `recipe`).
  - The deployer runs the deployment via **SSM RunCommand** (`AWS-RunShellScript`)
    on the instance. The deploy script redirects **all** output to the instance's
    local file `/var/log/tpot-bench/deploy.log`. **This is why
    `ssm get-command-invocation` only returns a top-level `exit status 1` — the
    real error lives in that file.** This is the key troubleshooting insight.
  - Compose file is written to `/opt/tpot-bench/scripts/<composeFile>` on the
    instance. Container names look like `scripts-prefill-1 / scripts-decode-1 /
    scripts-router-1` (PD topology) or `scripts-sglang-tp8-1` (TP8). Models are
    downloaded to `/opt/dlami/nvme/models/<modelName with "/" -> "__">`.

## Read-only diagnostic workflow

Run the scripts from inside the `scripts/` directory (each one sources
`../config.env`).

### Step 1 — Locate the booking

```bash
cd scripts
./check_booking.sh                 # list the most recent bookings
./check_booking.sh <bookingId>     # show one booking's status + key fields
```

Note the `status`, `instanceId`, `ssmCommandId`, and `deploymentPlan` (planId).

### Step 2 — Inspect the SSM command that ran the deploy

```bash
./get_ssm_command.sh <ssmCommandId> [instanceId]
```

This shows the top-level invocation result (usually `exit status 1`) **and** the
raw shell script that was sent to the instance. Remember: the truncated top-level
output is expected; the real error is inside `deploy.log` (Step 3).

### Step 3 — If the instance is still alive, read live logs over SSM (read-only)

```bash
./tail_deploy_log.sh <instanceId>
```

Runs read-only commands on the instance and returns their output:
`tail -n 200 /var/log/tpot-bench/deploy.log`, `docker ps -a`,
`docker logs --tail` for each container, `ls` of the model dir, `df -h`, and
`nvidia-smi`. **If the instance has been `terminated`, its local logs are gone;
fall back to the deployer Lambda logs in Step 4.**

### Step 4 — Pull deployer Lambda history logs

```bash
./deployer_logs.sh [bookingId] [since_iso]
# e.g. ./deployer_logs.sh b-1234 2026-09-14T00:00:00Z
```

Fetches `/aws/lambda/tpot-booking-deployer` log streams, filtered by `bookingId`
and/or a start time, and prints the relevant lines. Use this when the instance is
gone or when you want the orchestration side of the story.

### Step 5 — Compare plan.modelName vs compose --model-path

```bash
./inspect_plan.sh <planId> [instanceId]
```

Reads the DynamoDB plan record, fetches the referenced compose file (from the S3
`COMPOSE_BUCKET`, or from the live instance if `instanceId` is given), extracts the
`--model-path` value, and **highlights any mismatch** against `plan.modelName`.

### Step 6 — Check for full disk / fake RAID success

`tail_deploy_log.sh` already runs `df -h`. Look at the usage of
`/opt/dlami/nvme` vs `/`, and grep the deploy.log output for `mdadm`, `busy`,
`mount`.

## Failure decision tree (known patterns)

- **(a) Model mismatch** — the plan's `modelName` does not match the compose
  `--model-path` directory (e.g. plan `modelName=deepseek-ai/DeepSeek-V4-Flash`
  but compose expects `…__DeepSeek-V4-Flash-DSpark`). SGLang can't find the
  directory → container `Exited(1)` → deployer `exit 1`.
  **Diagnose with:** `inspect_plan.sh` (Step 5). Compare `plan.modelName` to the
  compose `--model-path`.
- **(b) NVMe RAID fake success / full disk** — the deploy script's Step 1
  unconditionally runs `mdadm --create` to grab the NVMe devices. On a DLAMI where
  the large disk is already mounted this fails with `Device or resource busy`,
  which is swallowed by `|| true` while it still prints a fake `mounted` message.
  The model then lands on the root disk, which can fill up.
  **Diagnose with:** search `deploy.log` for `mdadm` / `busy` / `mount`, and check
  `df -h` for `/opt/dlami/nvme` vs `/` usage (Steps 3 & 6).
- **(c) No capacity** — `status` stuck in `polling` (or `failed`) for a long time
  **with no `instanceId`**. **Diagnose with:** `check_booking.sh` (Step 1) plus
  `deployer_logs.sh` for capacity-related messages.
- **(d) Image pull / HF download failure** — errors from `docker pull` or
  `snapshot_download` in `deploy.log`. **Diagnose with:** `tail_deploy_log.sh`
  (Step 3), grep for `pull` / `snapshot_download`.
- **(e) DSpark preview needs draft-head weights** — the DSpark preview needs weights
  built with a draft head (`--speculative-algorithm DSPARK`); the stable release
  does not have them. This surfaces as a model-directory mismatch and rolls up into
  pattern **(a)**.

## How to read the conclusions

Once you have identified the pattern, **report it to the human operator with the
evidence** (the specific `deploy.log` lines, the `df -h` numbers, or the
`modelName` vs `--model-path` diff). **Do not attempt the fix yourself** — for
example, correcting the plan's `modelName`, editing the compose file, re-uploading
weights, or rebooking is a human action performed outside this skill. This skill's
job ends at "here is the root cause and the evidence."
