# Image Processing Serverless using AWS Lambda

A serverless image processing pipeline built on AWS Lambda, provisioned entirely with Terraform. Images uploaded to the source S3 bucket automatically trigger a Lambda function that produces five output variants — all without managing any servers.

---

## Architecture

```
Upload (PutObject)
      │
      ▼
┌─────────────┐    S3 event trigger    ┌──────────────────────────────────────┐
│ Source      │ ──────────────────────▶│         Lambda Function              │
│ S3 Bucket   │◀─ GetObject permission─│  ┌──────┐ ┌──────┐ ┌──────┐        │
└─────────────┘                        │  │JPEG  │ │JPEG  │ │WebP  │        │
                                       │  │ 85   │ │ 60   │ │      │        │
┌─────────────┐                        │  └──────┘ └──────┘ └──────┘        │
│ Destination │◀── PutObject ──────────│  ┌──────┐ ┌──────────────┐         │
│ S3 Bucket   │                        │  │ PNG  │ │ Thumb 200×200│         │
└─────────────┘                        │  └──────┘ └──────────────┘         │
                                       └─────────────────┬────────────────────┘
                                                         │ logs / metrics
                                                         ▼
                                                  ┌────────────┐
                                                  │ CloudWatch │
                                                  └────────────┘
```

---

## Resources Provisioned

| Resource | Description |
|---|---|
| `aws_s3_bucket.source` | Receives original image uploads |
| `aws_s3_bucket.destination` | Stores all processed image variants |
| `aws_iam_role.lambda_exec` | IAM execution role for Lambda |
| `aws_iam_policy.lambda_s3_policy` | S3 GetObject (source) + PutObject (destination) |
| `aws_lambda_function.image_processor` | Python 3.11 Lambda — produces 5 image variants |
| `aws_s3_bucket_notification.source_trigger` | Fires Lambda on every PutObject event |
| `aws_cloudwatch_log_group.lambda` | Stores Lambda logs with configurable retention |

---

## Image Output Variants

For every image uploaded (`image.jpg`) the Lambda produces:

| File | Format | Description |
|---|---|---|
| `image_q85.jpg` | JPEG | High quality (85) |
| `image_q60.jpg` | JPEG | Compressed (60) |
| `image.webp` | WebP | Modern format |
| `image.png` | PNG | Lossless |
| `image_thumb_200x200.jpg` | JPEG | Thumbnail 200×200 px |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.5
- AWS credentials configured (`aws configure` or environment variables)
- Python 3.11+ (only needed to update the Lambda package locally)

---

## Usage

```bash
# Initialise providers
terraform init

# Preview changes
terraform plan

# Deploy
terraform apply

# Tear down
terraform destroy
```

---

## Variables

| Name | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `source_bucket_name` | `image-processing-source-bucket-tf` | Source S3 bucket |
| `destination_bucket_name` | `image-processing-destination-bucket-tf` | Destination S3 bucket |
| `lambda_function_name` | `image-processor` | Lambda function name |
| `lambda_runtime` | `python3.11` | Lambda runtime |
| `lambda_timeout` | `60` | Timeout (seconds) |
| `lambda_memory_size` | `512` | Memory (MB) |
| `log_retention_days` | `14` | CloudWatch log retention |
| `thumbnail_width` | `200` | Thumbnail width (px) |
| `thumbnail_height` | `200` | Thumbnail height (px) |

---

## Project Structure

```
.
├── main.tf              # All AWS resources
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── providers.tf         # AWS provider configuration
├── lambda/
│   └── handler.py       # Python Lambda handler
└── lambda_function.zip  # Deployment package (auto-generated)
```

---

## License

[MIT](LICENSE)
