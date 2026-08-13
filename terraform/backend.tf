terraform {
  backend "s3" {
    bucket = "aleksandr607state"
    key    = "k3s-infra/terraform.tfstate"
    region = "us-east-1"
    endpoint = "https://storage.yandexcloud.net"

    dynamodb_endpoint = "https://docapi.serverless.yandexcloud.net/ru-central1/b1g820v8l43mp2cug27d/etnkp1cs6eto3cdq320u"
    dynamodb_table = "terraform-state-lock-db" 

    skip_region_validation      = true
    skip_credentials_validation = true
    skip_s3_checksum            = true
    skip_requesting_account_id  = true
    use_path_style             = true
  }
}


