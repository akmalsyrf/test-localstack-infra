variable "role_name" {
  type = string
}

variable "policy_name" {
  type = string
}

variable "policy_json" {
  type = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
