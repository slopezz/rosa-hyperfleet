# Break-glass AWS roles — assumed by API Lambda only (not boundary task role).

resource "aws_iam_role" "zoa_bg_aws_read" {
  name = "${local.function_prefix}-bg-aws-read"

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

resource "aws_iam_role_policy" "zoa_bg_aws_read" {
  name = "breakglass-read"
  role = aws_iam_role.zoa_bg_aws_read.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ec2:Describe*",
        "ec2:List*",
        "eks:Describe*",
        "eks:List*",
        "elasticloadbalancing:Describe*",
        "route53:List*",
        "route53:Get*",
        "logs:Describe*",
        "logs:FilterLogEvents",
        "logs:GetLogEvents",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "zoa_bg_aws_write" {
  name = "${local.function_prefix}-bg-aws-write"

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

resource "aws_iam_role_policy" "zoa_bg_aws_write" {
  name = "breakglass-write"
  role = aws_iam_role.zoa_bg_aws_write.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:RebootInstances", "ec2:StartInstances", "ec2:StopInstances"]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "zoa_bg_aws_elevated" {
  name = "${local.function_prefix}-bg-aws-elevated"

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

# Elevated scoped mutations — no AdministratorAccess.
resource "aws_iam_role_policy" "zoa_bg_aws_elevated" {
  name = "breakglass-elevated"
  role = aws_iam_role.zoa_bg_aws_elevated.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:UpdateAutoScalingGroup",
        "autoscaling:SetDesiredCapacity",
        "eks:UpdateNodegroupConfig",
      ]
      Resource = "*"
    }]
  })
}
