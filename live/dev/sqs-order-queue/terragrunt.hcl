include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//sqs"
}

inputs = {
  name                        = "order-queue"
  fifo                        = false
  content_based_deduplication = false
  high_throughput_fifo        = false
  visibility_timeout          = 30
  message_retention           = 86400
  max_message_size            = 262144
  delay_seconds               = 0
  receive_wait_time_seconds   = 0
  dlq_enabled                 = true
  dlq_max_receive_count       = 3
  dlq_message_retention       = 1209600
  kms_key_arn                 = ""
  extra_tags = {
    Component = "messaging"
  }
}
