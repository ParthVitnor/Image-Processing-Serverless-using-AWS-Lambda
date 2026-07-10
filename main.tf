# ─────────────────────────────────────────────
# S3 BUCKETS
# ─────────────────────────────────────────────

# Source bucket — original images are uploaded here
resource "aws_s3_bucket" "source" {
  bucket        = var.source_bucket_name
  force_destroy = true

  tags = {
    Name        = "Image Processing Source Bucket"
    Environment = "production"
    Project     = "image-processing-serverless"
  }
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Destination bucket — processed images land here
resource "aws_s3_bucket" "destination" {
  bucket        = var.destination_bucket_name
  force_destroy = true

  tags = {
    Name        = "Image Processing Destination Bucket"
    Environment = "production"
    Project     = "image-processing-serverless"
  }
}

resource "aws_s3_bucket_versioning" "destination" {
  bucket = aws_s3_bucket.destination.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "destination" {
  bucket = aws_s3_bucket.destination.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "destination" {
  bucket                  = aws_s3_bucket.destination.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ─────────────────────────────────────────────
# IAM ROLE & POLICIES FOR LAMBDA
# ─────────────────────────────────────────────

# Trust policy — allows Lambda service to assume this role
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.lambda_function_name}-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = {
    Project = "image-processing-serverless"
  }
}

# Policy — S3 GetObject on source, PutObject on destination
data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid     = "ReadSourceBucket"
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "${aws_s3_bucket.source.arn}/*"
    ]
  }

  statement {
    sid     = "WriteDestinationBucket"
    effect  = "Allow"
    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.destination.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "lambda_s3_policy" {
  name        = "${var.lambda_function_name}-s3-policy"
  description = "Allow Lambda to read from source S3 bucket and write to destination S3 bucket"
  policy      = data.aws_iam_policy_document.lambda_s3.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_s3_policy.arn
}

# Attach AWS managed policy for CloudWatch Logs (Lambda basic execution)
resource "aws_iam_role_policy_attachment" "lambda_cloudwatch" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ─────────────────────────────────────────────
# LAMBDA FUNCTION
# ─────────────────────────────────────────────

resource "aws_lambda_function" "image_processor" {
  function_name = var.lambda_function_name
  description   = "Processes uploaded images: JPEG(85), JPEG(60), WebP, PNG, Thumbnail 200x200"

  # Deployment package — built from ./lambda/handler.py
  filename         = "${path.module}/lambda_function.zip"
  source_code_hash = filebase64sha256("${path.module}/lambda_function.zip")

  handler = "handler.lambda_handler"
  runtime = var.lambda_runtime

  role        = aws_iam_role.lambda_exec.arn
  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_size

  environment {
    variables = {
      DESTINATION_BUCKET = aws_s3_bucket.destination.id
      THUMBNAIL_WIDTH    = tostring(var.thumbnail_width)
      THUMBNAIL_HEIGHT   = tostring(var.thumbnail_height)
    }
  }

  # Structured logging via CloudWatch
  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_s3,
    aws_iam_role_policy_attachment.lambda_cloudwatch,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = {
    Name    = var.lambda_function_name
    Project = "image-processing-serverless"
  }
}

# ─────────────────────────────────────────────
# CLOUDWATCH LOG GROUP
# ─────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "lambda" {
  # AWS Lambda automatically uses /aws/lambda/<function_name>
  name              = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days = var.log_retention_days

  tags = {
    Project = "image-processing-serverless"
  }
}
