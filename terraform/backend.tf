terraform {
  required_version = ">= 1.11.0"

  backend "s3" {
    key          = "infra/prod-simulated/infra-messaging/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
