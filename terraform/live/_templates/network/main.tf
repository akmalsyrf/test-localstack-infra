# Network: VPC + security group for EC2 backend

module "network" {
  source = "../../../modules/network"

  project_name    = var.project_name
  environment     = var.environment
  vpc_cidr_prefix = var.vpc_cidr_prefix
  tags            = local.tags
}

module "sg_ec2_backend" {
  source = "../../../modules/security-group"

  name                = "sg_${var.project_name}_ec2_backend_${var.environment_slug}"
  description         = "Security group for EC2 backend (${var.environment_slug})"
  vpc_id              = module.network.vpc_id
  ingress_cidr_blocks = [module.network.vpc_cidr_block]
  app_port            = 3000
  tags                = local.tags
}

output "vpc_id" {
  value = module.network.vpc_id
}

output "vpc_cidr_block" {
  value = module.network.vpc_cidr_block
}

output "public_subnet_ids" {
  value = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "security_group_id" {
  value = module.sg_ec2_backend.security_group_id
}

output "igw_id" {
  value = module.network.igw_id
}

output "public_subnet_count" {
  value = length(module.network.public_subnet_ids)
}

output "private_subnet_count" {
  value = length(module.network.private_subnet_ids)
}
