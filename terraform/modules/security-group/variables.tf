variable "name" {
  type = string
}

variable "description" {
  type    = string
  default = "security group for EC2 Backend"
}

variable "vpc_id" {
  type = string
}

variable "ingress_cidr_blocks" {
  type    = list(string)
  default = ["10.1.0.0/16"]
}

variable "app_port" {
  type    = number
  default = 3000
}

variable "tags" {
  type    = map(string)
  default = {}
}
