output "source_bucket_name" {
  description = "Name of the S3 source bucket"
  value       = aws_s3_bucket.source.id
}

output "source_bucket_arn" {
  description = "ARN of the S3 source bucket"
  value       = aws_s3_bucket.source.arn
}

output "destination_bucket_name" {
  description = "Name of the S3 destination bucket"
  value       = aws_s3_bucket.destination.id
}

output "destination_bucket_arn" {
  description = "ARN of the S3 destination bucket"
  value       = aws_s3_bucket.destination.arn
}

output "lambda_function_name" {
  description = "Name of the image processing Lambda function"
  value       = aws_lambda_function.image_processor.function_name
}

output "lambda_function_arn" {
  description = "ARN of the image processing Lambda function"
  value       = aws_lambda_function.image_processor.arn
}

output "lambda_iam_role_arn" {
  description = "ARN of the IAM role used by Lambda"
  value       = aws_iam_role.lambda_exec.arn
}

output "cloudwatch_log_group_name" {
  description = "CloudWatch log group name for Lambda logs"
  value       = aws_cloudwatch_log_group.lambda.name
}
