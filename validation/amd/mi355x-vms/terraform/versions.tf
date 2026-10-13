terraform {
  required_version = ">= 1.5"
  required_providers {
    crusoe = {
      source  = "registry.terraform.io/crusoecloud/crusoe"
      version = ">= 1.3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
