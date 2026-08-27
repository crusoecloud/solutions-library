terraform {
  required_version = ">= 1.9.0"
  required_providers {
    crusoe = {
      source  = "registry.terraform.io/crusoecloud/crusoe"
      version = "~> 0.5.44"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
