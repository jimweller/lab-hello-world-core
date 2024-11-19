terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket="terraform-remote-state-12345678901-us-east-1"
    key    = "fcc-demo-hello-world/fcc-demo-hello-world-core.tfstate"
    region = "us-east-1"
  }

  required_version = "~> 1.0"
}