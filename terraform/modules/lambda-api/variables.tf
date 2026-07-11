variable "prefix" {
  type = string
}

variable "stage_name" {
  type    = string
  default = "stg"
}

variable "lambda_zip_path" {
  type = string
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
