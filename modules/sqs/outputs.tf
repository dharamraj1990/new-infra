output "queue_url"  { value = aws_sqs_queue.this.id }
output "queue_arn"  { value = aws_sqs_queue.this.arn }
output "queue_name" { value = aws_sqs_queue.this.name }
output "dlq_arn"    { value = var.dlq_enabled ? aws_sqs_queue.dlq[0].arn : "" }
