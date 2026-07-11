plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

# Live stacks share _common/variables.tf; not every var is used in every stack
# (e.g. kind_* only on eks, tfc_organization only when BACKEND=cloud).
rule "terraform_unused_declarations" {
  enabled = false
}
