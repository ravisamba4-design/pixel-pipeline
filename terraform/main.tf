terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Bucket where users upload original images
resource "aws_s3_bucket" "uploads" {
  bucket = "${var.project_name}-uploads-${var.unique_suffix}"
}

# Bucket where processed images land
resource "aws_s3_bucket" "processed" {
  bucket = "${var.project_name}-processed-${var.unique_suffix}"
}

# Queue that decouples the upload trigger from the processing work
resource "aws_sqs_queue" "image_jobs" {
  name                       = "${var.project_name}-image-jobs"
  visibility_timeout_seconds = 60
}

# Table tracking the status of each processing job
resource "aws_dynamodb_table" "jobs" {
  name         = "${var.project_name}-jobs"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }
}
