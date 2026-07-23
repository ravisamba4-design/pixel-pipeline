variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-north-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "pixel-pipeline"
}

variable "unique_suffix" {
  description = "Unique suffix to avoid S3 bucket name collisions globally"
  type        = string
}
