include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//sns"
}

inputs = {
  name         = "order-events"
  fifo         = false
  display_name = "Order Events Topic"
  subscriptions = [
    {
      protocol = "email"
      endpoint = "ops@op2mise.com"
    },
  ]
  extra_tags = {
    Component = "messaging"
  }
}
