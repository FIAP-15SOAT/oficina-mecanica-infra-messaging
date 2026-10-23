variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Base project name used to compose resource names"
  type        = string
  default     = "oficina-mecanica"
}

variable "environment" {
  description = "Environment name used for default resource tagging"
  type        = string
  default     = "prod-simulated"
}
