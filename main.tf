# ─────────────────────────────────────────────
# S3 BUCKETS
# ─────────────────────────────────────────────

# Source bucket — original images are uploaded here
resource "aws_s3_bucket" "source" {
  bucket        = var.source_bucket_name
  force_destroy = var.force_destroy_buckets

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
  force_destroy = var.force_destroy_buckets

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
# LAMBDA PACKAGING
# ─────────────────────────────────────────────
# The deployment zip contains only handler.py — Pillow is supplied via a
# Lambda Layer (see layers = [...] on aws_lambda_function.image_processor).
# This avoids the archive_file / null_resource timing problem where
# archive_file evaluates at plan time but null_resource pip install runs
# at apply time, causing "source_dir does not exist" on first apply.

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda_function.zip"
}

# ─────────────────────────────────────────────
# PILLOW LAMBDA LAYER
# ─────────────────────────────────────────────
# Public Klayers ARN for Pillow on Python 3.11 in us-east-1.
# Source: https://github.com/keithrozario/Klayers
# To update: check the latest ARN for your region at the Klayers repo.
locals {
  pillow_layer_arn = "arn:aws:lambda:${var.aws_region}:770693421928:layer:Klayers-p311-Pillow:4"
}

# ─────────────────────────────────────────────
# LAMBDA FUNCTION
# ─────────────────────────────────────────────

resource "aws_lambda_function" "image_processor" {
  function_name = var.lambda_function_name
  description   = "Processes uploaded images: JPEG(85), JPEG(60), WebP, PNG, Thumbnail 200x200"

  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  handler = "handler.lambda_handler"
  runtime = var.lambda_runtime

  # Pillow is provided via the public Klayers layer — no need to bundle it
  layers = [local.pillow_layer_arn]

  role        = aws_iam_role.lambda_exec.arn
  timeout     = var.lambda_timeout
  memory_size = var.lambda_memory_size

  # Limit concurrency to prevent runaway invocations (e.g. recursive trigger)
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  # Route failed async invocations to the SQS DLQ
  dead_letter_config {
    target_arn = aws_sqs_queue.dlq.arn
  }

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
    aws_iam_role_policy_attachment.lambda_dlq,
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

# ─────────────────────────────────────────────
# DEAD LETTER QUEUE (SQS)
# ─────────────────────────────────────────────

# SQS queue to catch failed async Lambda invocations
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.lambda_function_name}-dlq"
  message_retention_seconds = 1209600 # 14 days — enough time to inspect and replay

  tags = {
    Project = "image-processing-serverless"
  }
}

# Allow Lambda service to send messages to the DLQ
data "aws_iam_policy_document" "dlq_send" {
  statement {
    sid    = "AllowLambdaSendMessage"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_lambda_function.image_processor.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy    = data.aws_iam_policy_document.dlq_send.json
}

# Grant the Lambda execution role permission to send to the DLQ
data "aws_iam_policy_document" "lambda_dlq" {
  statement {
    sid     = "SendToDLQ"
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.dlq.arn]
  }
}

resource "aws_iam_policy" "lambda_dlq_policy" {
  name        = "${var.lambda_function_name}-dlq-policy"
  description = "Allow Lambda execution role to send failed events to SQS DLQ"
  policy      = data.aws_iam_policy_document.lambda_dlq.json
}

resource "aws_iam_role_policy_attachment" "lambda_dlq" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dlq_policy.arn
}

# Wire up async invocation settings: 2 retries then route to DLQ
resource "aws_lambda_function_event_invoke_config" "image_processor" {
  function_name          = aws_lambda_function.image_processor.function_name
  maximum_retry_attempts = 2

  destination_config {
    on_failure {
      destination = aws_sqs_queue.dlq.arn
    }
  }
}



# S3 → LAMBDA TRIGGER
# ─────────────────────────────────────────────

# Allow S3 to invoke the Lambda function
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.source.arn
}

# S3 bucket notification — fires Lambda on any object creation event
# (Put, CompleteMultipartUpload, Copy) for common image extensions.
# Both lowercase and uppercase suffixes are covered via separate filter blocks
# because S3 suffix filters are case-sensitive.
resource "aws_s3_bucket_notification" "source_trigger" {
  bucket = aws_s3_bucket.source.id

  # ── .jpg / .JPG ──────────────────────────────────────────────────────────
  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".JPG"
  }

  # ── .jpeg / .JPEG ────────────────────────────────────────────────────────
  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".jpeg"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".JPEG"
  }

  # ── .png / .PNG ──────────────────────────────────────────────────────────
  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".png"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".PNG"
  }

  # ── .webp / .WEBP ────────────────────────────────────────────────────────
  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".webp"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.image_processor.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".WEBP"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
