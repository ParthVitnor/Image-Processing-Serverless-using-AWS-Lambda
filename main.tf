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
