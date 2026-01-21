terraform {
  required_version = ">= 1.0"
  
  required_providers {
    crusoe = {
      source  = "crusoecloud/crusoe"
      version = "~> 1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "crusoe" {
}
