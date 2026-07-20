terraform {
  backend "s3" {
    bucket   = "aleksandr607state"
    key      = "k3s-infra/terraform.tfstate"
    region   = "us-east-1"
    endpoint = "https://storage.yandexcloud.net"

    # Отключаем AWS-специфичные проверки для совместимости с Yandex Object Storage
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_s3_checksum            = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }

  required_providers {
    yandex = {
      source  = "registry.terraform.io/yandex-cloud/yandex"
      version = ">= 0.13.0"
    }
    local = {
      source  = "registry.terraform.io/hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

provider "yandex" {
  token     = var.yc_token
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
}










