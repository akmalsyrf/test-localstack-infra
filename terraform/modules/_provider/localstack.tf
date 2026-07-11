# Shared LocalStack provider snippet — copy into each live stack's provider.tf
# (Terraform does not support including providers from modules.)
#
# provider "aws" {
#   access_key                  = "test"
#   secret_key                  = "test"
#   region                      = "ap-southeast-3"
#   s3_use_path_style           = true
#   skip_credentials_validation = true
#   skip_metadata_api_check     = true
#   skip_requesting_account_id  = true
#
#   endpoints {
#     apigateway     = "http://localhost:4566"
#     cloudwatch     = "http://localhost:4566"
#     logs           = "http://localhost:4566"
#     ec2            = "http://localhost:4566"
#     iam            = "http://localhost:4566"
#     lambda         = "http://localhost:4566"
#     s3             = "http://localhost:4566"
#     secretsmanager = "http://localhost:4566"
#     sns            = "http://localhost:4566"
#     sqs            = "http://localhost:4566"
#     ssm            = "http://localhost:4566"
#     sts            = "http://localhost:4566"
#   }
# }
