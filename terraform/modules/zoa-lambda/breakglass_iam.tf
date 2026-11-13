# Break-glass AWS roles — assumed by API Lambda only (not boundary task role).
# Read: AWS ReadOnlyAccess. Write: ReadOnly + state-change mutations (no desired-state / data-plane edits).
# Elevated: PowerUserAccess + explicit Deny on ZOA S3/Dynamo data and KMS destruction.

locals {
  enable_breakglass = var.breakglass_table_name != ""

  # ZOA DynamoDB + S3 artifact data live in the RC data account (MC passes cross-account ARNs).
  zoa_data_account_id = coalesce(
    try(split(":", var.kms_key_arn)[4], null),
    try(split(":", var.artifact_bucket_arn)[4], null),
    data.aws_caller_identity.current.account_id,
  )

  zoa_breakglass_dynamodb_tables = compact([
    var.dynamodb_table_name,
    var.audit_table_name,
    var.sessions_table_name,
    var.breakglass_table_name,
  ])

  zoa_breakglass_dynamodb_arns = flatten([
    for table in local.zoa_breakglass_dynamodb_tables : [
      "arn:aws:dynamodb:${data.aws_region.current.region}:${local.zoa_data_account_id}:table/${table}",
      "arn:aws:dynamodb:${data.aws_region.current.region}:${local.zoa_data_account_id}:table/${table}/index/*",
    ]
  ])

  # Seaplane Aurora, ElastiCache (Valkey), and fleet DB are RC-only; MC break-glass is account-local (EKS/MC AWS).
  breakglass_aws_write_state_mutations = var.target_type == "rc"

  zoa_lambda_function_arns = [
    aws_lambda_function.api.arn,
    aws_lambda_function.worker.arn,
  ]
}

resource "aws_iam_role" "zoa_bg_aws_read" {
  count = local.enable_breakglass ? 1 : 0
  name  = "${local.function_prefix}-bg-aws-read"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.function_prefix}-bg-aws-read" })
}

resource "aws_iam_role_policy_attachment" "zoa_bg_aws_read" {
  count      = local.enable_breakglass ? 1 : 0
  role       = aws_iam_role.zoa_bg_aws_read[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role" "zoa_bg_aws_write" {
  count = local.enable_breakglass ? 1 : 0
  name  = "${local.function_prefix}-bg-aws-write"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.function_prefix}-bg-aws-write" })
}

resource "aws_iam_role_policy_attachment" "zoa_bg_aws_write_readonly" {
  count      = local.enable_breakglass ? 1 : 0
  role       = aws_iam_role.zoa_bg_aws_write[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "zoa_bg_aws_write_mutations" {
  count = local.enable_breakglass && local.breakglass_aws_write_state_mutations ? 1 : 0
  name  = "breakglass-write-mutations"
  role  = aws_iam_role.zoa_bg_aws_write[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "StateChangeMutationsRC"
      Effect = "Allow"
      Action = [
        "ec2:RebootInstances",
        "ec2:StartInstances",
        "ec2:StopInstances",
        "rds:RebootDBCluster",
        "elasticache:RebootCacheCluster",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "zoa_bg_aws_elevated" {
  count = local.enable_breakglass ? 1 : 0
  name  = "${local.function_prefix}-bg-aws-elevated"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${local.function_prefix}-bg-aws-elevated" })
}

resource "aws_iam_role_policy_attachment" "zoa_bg_aws_elevated_poweruser" {
  count      = local.enable_breakglass ? 1 : 0
  role       = aws_iam_role.zoa_bg_aws_elevated[0].name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

# ZOA immutability: break-glass elevated must not mutate TA artifact data or Dynamo item data (Lambda owns writes).
# dynamodb:UpdateTable is table/config (capacity, GSIs) — not row writes; item APIs are denied above.
# MC elevated uses PowerUser in the MC account; RC-centric denies use ARNs from vars (cross-account where needed).
resource "aws_iam_role_policy" "zoa_bg_aws_elevated_zoa_guards" {
  count = local.enable_breakglass ? 1 : 0
  name  = "breakglass-elevated-zoa-immutability"
  role  = aws_iam_role.zoa_bg_aws_elevated[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      var.artifact_bucket_arn != "" ? [{
        Sid    = "DenyZoaArtifactBucketMutation"
        Effect = "Deny"
        Action = [
          "s3:DeleteBucket",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:PutObjectAcl",
          "s3:PutObjectTagging",
          "s3:DeleteObjectTagging",
          "s3:AbortMultipartUpload",
        ]
        Resource = [
          var.artifact_bucket_arn,
          "${var.artifact_bucket_arn}/*",
        ]
      }] : [],
      length(local.zoa_breakglass_dynamodb_arns) > 0 ? [
        {
          Sid    = "DenyZoaDynamoRowMutation"
          Effect = "Deny"
          Action = [
            "dynamodb:DeleteItem",
            "dynamodb:PutItem",
            "dynamodb:UpdateItem",
            "dynamodb:BatchWriteItem",
          ]
          Resource = local.zoa_breakglass_dynamodb_arns
        },
        {
          Sid    = "DenyZoaDynamoTableDestroy"
          Effect = "Deny"
          Action = [
            "dynamodb:DeleteTable",
            "dynamodb:DeleteBackup",
          ]
          Resource = local.zoa_breakglass_dynamodb_arns
        },
      ] : [],
      var.kms_key_arn != "" ? [{
        Sid    = "DenyZoaKmsDestructive"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion",
          "kms:DisableKey",
          "kms:DeleteImportedKeyMaterial",
          "kms:DeleteAlias",
        ]
        Resource = var.kms_key_arn
      }] : [],
      [{
        Sid    = "DenyZoaLambdaCodeMutation"
        Effect = "Deny"
        Action = [
          "lambda:DeleteFunction",
          "lambda:UpdateFunctionCode",
          "lambda:UpdateFunctionConfiguration",
          "lambda:PublishVersion",
        ]
        Resource = local.zoa_lambda_function_arns
      }],
      # Operators join their boundary via Access-vended ecs:ExecuteCommand (per-task session policy).
      # PowerUser on bg-elevated must not Exec into any ZOA boundary task (cross-session impersonation).
      [{
        Sid    = "DenyZoaBoundaryECSExec"
        Effect = "Deny"
        Action = [
          "ecs:ExecuteCommand",
        ]
        Resource = [
          aws_ecs_cluster.boundary.arn,
          "arn:aws:ecs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:task/${aws_ecs_cluster.boundary.name}/*",
        ]
      }],
    )
  })
}
