# ZOA Lambda Infrastructure

**Last Updated Date**: 2026-08-20

## Summary

AWS infrastructure for the ZOA Lambda deployment model: a 2-Lambda-per-VPC architecture with shared data layer (DynamoDB, S3, KMS, ECR) in the Regional Cluster and per-VPC compute (API + Worker Lambdas) deployed to each cluster's VPC. All configuration is tunable via Terraform variables without code changes.

## Architecture

ZOA uses a **2-Lambda per VPC** model:

| Lambda     | Trigger                             | Purpose                                              | Timeout | Concurrency |
| ---------- | ----------------------------------- | ---------------------------------------------------- | ------- | ----------- |
| **API**    | Function URL (IAM auth, streaming)  | CLI requests, sync TA execution, streaming downloads | 300s    | 50          |
| **Worker** | EventBridge Scheduler + self-invoke | Reconciler, GC, async TA execution                   | 300s    | 10          |

Both share the same container image (ECR), IAM execution role, and binary. `HANDLER_MODE` env var selects the execution path (API uses native Go streaming via `LambdaFunctionURLStreamingResponse`; Worker calls `lambda.Start()` for native event handling).

## Terraform Module Split

```
terraform/modules/zoa/          → Data layer (DynamoDB, S3, KMS, ECR, IAM)
                                  Lives only in RC. MC access via resource policies.

terraform/modules/zoa-lambda/   → Compute layer (Lambdas, EventBridge, SQS DLQ, CW Logs)
                                  Deployed once per VPC (RC + each MC).
```

## Tunable Parameters

All timeouts and batch sizes are **configurable without code change** via Terraform variables that map to Lambda environment variables.

### Terraform Variables (in `zoa-lambda` module)

| Variable                      | Default | Purpose                                            | Safe range                |
| ----------------------------- | ------- | -------------------------------------------------- | ------------------------- |
| `lambda_api_timeout`          | 300     | API Lambda hard ceiling (seconds)                  | 60–900                    |
| `lambda_worker_timeout`       | 300     | Worker Lambda hard ceiling (seconds)               | 60–900                    |
| `lambda_api_concurrency`      | 50      | Max concurrent API Lambda invocations              | 1–1000                    |
| `lambda_worker_concurrency`   | 10      | Max concurrent Worker Lambda invocations           | 2–100                     |
| `reconciler_deadline_seconds` | 55      | Code-level deadline for reconciler/GC              | < `lambda_worker_timeout` |
| `max_batch_per_tick`          | 30      | Items processed per scheduled phase per tick       | 1–200                     |
| `lambda_memory_size`          | 512     | Memory in MB (also affects CPU proportionally)     | 128–10240                 |
| `enable_reconciler`           | true    | Toggle EventBridge schedules (disable for testing) | true/false                |
| `dynamodb_ttl_days`           | 365     | DynamoDB record retention (FIPS compliance)        | 30–3650                   |

### Lambda Environment Variables

**Common (both API and Worker):**

| Env Var                             | Set from                                | Controls                                   |
| ----------------------------------- | --------------------------------------- | ------------------------------------------ |
| `EXECUTION_TABLE`                   | `var.dynamodb_table_name`               | DynamoDB executions table                  |
| `AUDIT_TABLE`                       | `var.audit_table_name`                  | DynamoDB audit table                       |
| `ARTIFACT_BUCKET`                   | `var.artifact_bucket_name`              | S3 bucket for output/logs                  |
| `KMS_KEY_ARN`                       | `var.kms_key_arn`                       | Encryption key for S3 objects              |
| `JOB_IMAGE`                         | `var.job_image_uri`                     | Container image for async K8s Jobs         |
| `ZOA_JOBS_NAMESPACE`                | `var.zoa_jobs_namespace`                | K8s namespace for async Jobs               |
| `TARGET_CLUSTER`                    | `var.cluster_id`                        | Target cluster ID (shown in `zoa version`) |
| `EKS_CLUSTER_ENDPOINT`              | `var.eks_cluster_endpoint`              | Private EKS API endpoint URL               |
| `EKS_CLUSTER_CA`                    | `var.eks_cluster_ca`                    | EKS cluster CA cert (base64)               |
| `EKS_CLUSTER_NAME`                  | `var.eks_cluster_name`                  | EKS cluster name (for STS token)           |
| `UPLOADER_ROLE_ARN`                 | `var.uploader_role_arn`                 | STS role for S3 upload in async Jobs       |
| `AWS_READ_ROLE_ARN`                 | `aws_iam_role.zoa_aws_read.arn`         | STS role for aws-api read TAs              |
| `AWS_WRITE_ROLE_ARN`                | `aws_iam_role.zoa_aws_write.arn`        | STS role for aws-api write TAs             |
| `WRITE_COOLDOWN_SECONDS`            | `var.write_cooldown_seconds`            | Per-target write rate limit                |
| `MAX_CONCURRENT_PER_TARGET`         | `var.max_concurrent_per_target`         | Max parallel writes per target             |
| `ASYNC_SCHEDULING_OVERHEAD_SECONDS` | `var.async_scheduling_overhead_seconds` | Buffer added to TA timeout for async       |
| `DYNAMODB_TTL_DAYS`                 | `var.dynamodb_ttl_days`                 | Record retention (TTL)                     |
| `DATA_STORE_ROLE_ARN`               | `var.data_access_role_arn`              | Cross-account role (MC→RC data, optional)  |
| `LOG_LEVEL`                         | `var.log_level`                         | Structured log verbosity                   |

**API Lambda only:**

| Env Var                      | Set from                 | Controls                                        |
| ---------------------------- | ------------------------ | ----------------------------------------------- |
| `HANDLER_MODE`               | `"api"` (fixed)          | Native Go streaming handler (Function URL)      |
| `EXECUTION_DEADLINE_SECONDS` | `lambda_api_timeout - 5` | Code deadline for sync TA execution             |

**Worker Lambda only:**

| Env Var                       | Set from                          | Controls                           |
| ----------------------------- | --------------------------------- | ---------------------------------- |
| `HANDLER_MODE`                | `"worker"` (fixed)                | Uses `lambda.Start()` for events   |
| `RECONCILER_DEADLINE_SECONDS` | `var.reconciler_deadline_seconds` | Code deadline for scheduled routes |
| `EXECUTION_DEADLINE_SECONDS`  | `lambda_worker_timeout - 5`       | Code deadline for TA execution     |
| `MAX_BATCH_PER_TICK`          | `var.max_batch_per_tick`          | Batch limit per phase              |
| `AWS_LAMBDA_FUNCTION_NAME`    | AWS (auto-set)                    | Used for self-invocation (fan-out) |

## EventBridge Schedules

| Schedule                   | Rate      | Target Route | State                             |
| -------------------------- | --------- | ------------ | --------------------------------- |
| `{cluster}-zoa-reconciler` | 1 minute  | `reconciler` | Enabled (via `enable_reconciler`) |
| `{cluster}-zoa-gc`         | 5 minutes | `gc`         | Enabled (via `enable_reconciler`) |

## Self-Invocation (Fan-out)

The Worker Lambda invokes **itself** for TA execution:

- Reconciler claims approved executions → transitions to `dispatched`
- Invokes `AWS_LAMBDA_FUNCTION_NAME` with `InvocationType=Event`
- AWS Lambda queues the invocation in a separate concurrent slot
- `reserved_concurrency=10` ensures max 9 concurrent TA executions + 1 for reconciler

## Security Model

- **Function URL**: `AWS_IAM` auth only — requires valid SigV4 signature
- **VPC attachment**: Lambda runs inside the target VPC using the cluster security group (passed as variable, not self-managed)
- **SQS DLQ**: SSE-SQS encryption, 14-day retention. Only effective for Worker (async invocations from EventBridge/self-invoke). API Lambda returns 429 directly to the caller on throttle — DLQ not triggered for synchronous Function URL calls.
- **KMS**: DynamoDB and S3 encrypted at rest via dedicated KMS key
- **Cross-account**: MC Lambdas assume a `data-access` IAM role in the RC account (STS AssumeRole). DynamoDB and S3 also have resource-based policies scoped by OU path as defense in depth.
- **TA scoped roles**: Separate `zoa-aws-read` and `zoa-aws-write` IAM roles assumed per TA execution (EKS, EC2, VPC permissions). Lambda itself never has those permissions directly.

## Monitoring

| Signal              | Source               | How                                            |
| ------------------- | -------------------- | ---------------------------------------------- |
| Lambda errors       | AWS/Lambda namespace | Auto-published by Lambda runtime               |
| Duration, throttles | AWS/Lambda namespace | Auto-published by Lambda runtime               |
| Business metrics    | ZOA/Custom namespace | EMF logs emitted by Go code                    |
| Alerting            | Prometheus           | CW Exporter scrapes → PrometheusRules evaluate |
| Logs                | CloudWatch Logs      | 365-day retention, JSON structured             |

## Deployment Flow

1. Konflux/Tekton builds container image from `rosa-hyperfleet-zoa` (x86_64)
2. Image pushed to Quay registry
3. Pipeline mirrors image from Quay → ECR via skopeo (Lambda only admits ECR as image source). Temporary workaround until Konflux pushes directly to ECR.
4. Terraform `image_uri` variable updated with new ECR tag
5. `terraform apply` updates Lambda to use new image

## Cost Considerations

- Lambda bills per-ms of actual execution, not per-timeout
- Reserved concurrency guarantees slots but doesn't incur idle cost
- x86_64 architecture (Graviton/arm64 migration possible for ~20% savings)
- EventBridge Scheduler: free tier covers most schedules
- SQS DLQ: minimal cost (14-day retention, encrypted)
