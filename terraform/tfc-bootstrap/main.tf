terraform {
  required_version = ">= 1.5.0"

  required_providers {
    tfe = {
      source  = "hashicorp/tfe"
      version = ">= 0.74.0, < 1.0.0"
    }
  }

  backend "local" {}
}

provider "tfe" {
  # export TFE_TOKEN=...  (or TF_TOKEN_app_terraform_io)
}

variable "organization" {
  type        = string
  description = "Terraform Cloud organization name"
  default     = "ExperimentTerraform"
}

variable "project_name" {
  type        = string
  description = "Prefix for TFC projects and workspaces"
  default     = "testinfra"
}

variable "environments" {
  type    = list(string)
  default = ["dev", "staging"]
}

resource "tfe_project" "shared" {
  organization = var.organization
  name         = "${var.project_name}-shared"
  description  = "Shared / platform resources (S3, Secrets, IAM)"
}

resource "tfe_project" "network" {
  organization = var.organization
  name         = "${var.project_name}-network"
  description  = "Network resources (VPC, subnets, security groups)"
}

resource "tfe_project" "backend" {
  organization = var.organization
  name         = "${var.project_name}-backend"
  description  = "Backend application resources (EC2, Lambda, API GW, SNS/SQS)"
}

resource "tfe_project" "eks" {
  organization = var.organization
  name         = "${var.project_name}-eks"
  description  = "EKS (LocalStack API) backed by Kind + sample workload"
}

locals {
  projects = {
    shared  = tfe_project.shared.id
    network = tfe_project.network.id
    backend = tfe_project.backend.id
    eks     = tfe_project.eks.id
  }

  workspaces = flatten([
    for project_key, project_id in local.projects : [
      for env in var.environments : {
        key        = "${project_key}-${env}"
        name       = "${var.project_name}-${project_key}-${env}"
        project_id = project_id
        project    = project_key
        env        = env
      }
    ]
  ])
}

# State lives in TFC; plan/apply run in GitHub Actions or on a laptop (local execution).
# Do NOT set working_directory for VCS remote runs — relative module paths
# (../../../modules) only resolve when Terraform runs locally with the full repo.
resource "tfe_workspace" "this" {
  for_each = { for w in local.workspaces : w.key => w }

  name           = each.value.name
  organization   = var.organization
  project_id     = each.value.project_id
  queue_all_runs = false
  auto_apply     = false

  # Speculative plans from the UI/VCS are useless here (LocalStack is not reachable
  # from TFC agents). Keep CLI-driven local runs only.
  speculative_enabled = false
  file_triggers_enabled = false

  tag_names = [
    "app:${var.project_name}",
    "project:${each.value.project}",
    "env:${each.value.env}",
    "org:${var.organization}",
    "execution:local",
  ]
}

# Explicit overwrite of org/project default (usually remote). Without this,
# terraform init + cloud {} can auto-create workspaces that run remotely and
# fail with: Unreadable module directory ../../../modules
resource "tfe_workspace_settings" "this" {
  for_each = tfe_workspace.this

  workspace_id        = each.value.id
  execution_mode      = "local"
  global_remote_state = true
}

# Project-level default so newly created / UI-reset workspaces inherit local.
resource "tfe_project_settings" "this" {
  for_each = local.projects

  project_id             = each.value
  default_execution_mode = "local"
}

output "organization" {
  value = var.organization
}

output "projects" {
  value = {
    shared  = { id = tfe_project.shared.id, name = tfe_project.shared.name }
    network = { id = tfe_project.network.id, name = tfe_project.network.name }
    backend = { id = tfe_project.backend.id, name = tfe_project.backend.name }
    eks     = { id = tfe_project.eks.id, name = tfe_project.eks.name }
  }
}

output "workspaces" {
  value = {
    for k, ws in tfe_workspace.this : k => {
      id   = ws.id
      name = ws.name
    }
  }
}

output "workspace_map" {
  description = "Quick reference: project × env → workspace name"
  value = {
    for w in local.workspaces : "${w.project}/${w.env}" => w.name
  }
}
