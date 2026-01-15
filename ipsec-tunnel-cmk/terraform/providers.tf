terraform {
  required_version = ">= 1.6.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.26.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.1"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "helm" {
    kubernetes = {
        config_path = "~/.kube/config.ipsec"
    }
}
