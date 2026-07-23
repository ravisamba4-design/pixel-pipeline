terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
    klayers = {
      source  = "ldcorentin/klayer"
      version = "~> 1.0.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "klayers_package_latest_version" "pillow" {
  name           = "Pillow"
  region         = var.aws_region
  python_version = "3.12"
}

# ---------- Core storage/queue resources ----------

resource "aws_s3_bucket" "uploads" {
  bucket = "${var.project_name}-uploads-${var.unique_suffix}"
}

resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${var.unique_suffix}"
}

resource "aws_sqs_queue" "image_jobs" {
  name                       = "${var.project_name}-image-jobs"
  visibility_timeout_seconds = 60
}

resource "aws_dynamodb_table" "jobs" {
  name         = "${var.project_name}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}

# ---------- Package Lambda code into zip files ----------

data "archive_file" "trigger_handler_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/trigger_handler"
  output_path = "${path.module}/trigger_handler.zip"
}

data "archive_file" "processor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../lambda/processor"
  output_path = "${path.module}/processor.zip"
}

# ---------- IAM role for trigger_handler Lambda ----------

resource "aws_iam_role" "trigger_handler_role" {
  name = "${var.project_name}-trigger-handler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "trigger_handler_policy" {
  name = "${var.project_name}-trigger-handler-policy"
  role = aws_iam_role.trigger_handler_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.image_jobs.arn
      }
    ]
  })
}

# ---------- IAM role for processor Lambda ----------

resource "aws_iam_role" "processor_role" {
  name = "${var.project_name}-processor-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "processor_policy" {
  name = "${var.project_name}-processor-policy"
  role = aws_iam_role.processor_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.uploads.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.processed.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:UpdateItem"]
        Resource = aws_dynamodb_table.jobs.arn
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = aws_sqs_queue.image_jobs.arn
      }
    ]
  })
}

# ---------- Lambda functions ----------

resource "aws_lambda_function" "trigger_handler" {
  function_name    = "${var.project_name}-trigger-handler"
  filename         = data.archive_file.trigger_handler_zip.output_path
  source_code_hash = data.archive_file.trigger_handler_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.trigger_handler_role.arn
  timeout          = 15

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.image_jobs.url
    }
  }
}

resource "aws_lambda_function" "processor" {
  function_name    = "${var.project_name}-processor"
  filename         = data.archive_file.processor_zip.output_path
  source_code_hash = data.archive_file.processor_zip.output_base64sha256
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  role             = aws_iam_role.processor_role.arn
  timeout          = 30
  memory_size      = 512

  layers = [data.klayers_package_latest_version.pillow.arn]

  environment {
    variables = {
      PROCESSED_BUCKET = aws_s3_bucket.processed.bucket
    }
  }
}

# ---------- Wire up S3 -> trigger_handler ----------

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger_handler.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.uploads.arn
}

resource "aws_s3_bucket_notification" "upload_trigger" {
  bucket = aws_s3_bucket.uploads.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger_handler.arn
    events               = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.allow_s3_invoke]
}

# ---------- Wire up SQS -> processor ----------

resource "aws_lambda_event_source_mapping" "sqs_to_processor" {
  event_source_arn = aws_sqs_queue.image_jobs.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1
}
