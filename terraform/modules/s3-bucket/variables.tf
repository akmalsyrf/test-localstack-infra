variable "bucket" {
  type = string
}

variable "versioning_enabled" {
  type    = bool
  default = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
