variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "source_bucket_name" {
  description = "Name of the S3 source bucket where original images are uploaded"
  type        = string
  default     = "image-processing-source-bucket-tf"
}

variable "destination_bucket_name" {
  description = "Name of the S3 destination bucket where processed images are stored"
  type        = string
  default     = "image-processing-destination-bucket-tf"
}

variable "lambda_function_name" {
  description = "Name of the Lambda function for image processing"
  type        = string
  default     = "image-processor"
}

variable "lambda_runtime" {
  description = "Runtime for the Lambda function"
  type        = string
  default     = "python3.11"
}

variable "lambda_timeout" {
  description = "Timeout in seconds for the Lambda function"
  type        = number
  default     = 60
}

variable "lambda_memory_size" {
  description = "Memory size in MB for the Lambda function"
  type        = number
  default     = 512
}

variable "log_retention_days" {
  description = "Number of days to retain CloudWatch logs"
  type        = number
  default     = 14
}

variable "thumbnail_width" {
  description = "Width in pixels for the generated thumbnail"
  type        = number
  default     = 200
}

variable "thumbnail_height" {
  description = "Height in pixels for the generated thumbnail"
  type        = number
  default     = 200
}
