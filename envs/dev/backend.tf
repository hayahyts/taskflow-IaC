terraform {
  backend "s3" {
    bucket         = "taskflow-tfstate-226680475141"
    key            = "envs/dev/terraform.tfstate"
    region         = "us-east-2"
    dynamodb_table = "taskflow-tf-locks"
    encrypt        = true
  }
}


