variable "aws_region" {
  description = "AWS region for bootstrap resources"
  type        = string
  default     = "us-east-2"
}

provider "aws" {
  region = var.aws_region
}



