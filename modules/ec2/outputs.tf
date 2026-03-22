output "instance_id" {
  description = "EC2 instance ID (empty when ASG is enabled)"
  value       = var.asg_enabled ? "" : (length(aws_instance.this) > 0 ? aws_instance.this[0].id : "")
}

output "instance_private_ip" {
  description = "Private IP of the instance (empty when ASG is enabled)"
  value       = var.asg_enabled ? "" : (length(aws_instance.this) > 0 ? aws_instance.this[0].private_ip : "")
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = aws_launch_template.this.id
}

output "launch_template_arn" {
  description = "ARN of the launch template"
  value       = aws_launch_template.this.arn
}

output "asg_name" {
  description = "Name of the Auto Scaling Group (empty when ASG is disabled)"
  value       = var.asg_enabled ? aws_autoscaling_group.this[0].name : ""
}

output "security_group_ids" {
  description = "List of security group IDs attached to the instance"
  value       = local.sg_ids
}

output "iam_role_arn" {
  description = "ARN of the IAM role attached to the instance"
  value       = var.iam_role_create ? aws_iam_role.this[0].arn : ""
}

output "iam_role_name" {
  description = "Name of the IAM role attached to the instance"
  value       = var.iam_role_create ? aws_iam_role.this[0].name : ""
}

output "instance_profile_name" {
  description = "Name of the IAM instance profile"
  value       = local.instance_profile
}

output "key_pair_name" {
  description = "Name of the EC2 key pair"
  value       = local.key_name
}

output "private_key_secret_arn" {
  description = "Secrets Manager ARN containing the private key PEM"
  value       = var.key_pair_create ? aws_secretsmanager_secret.private_key[0].arn : ""
}

output "private_key_secret_name" {
  description = "Secrets Manager secret name containing the private key PEM"
  value       = var.key_pair_create ? aws_secretsmanager_secret.private_key[0].name : ""
}
