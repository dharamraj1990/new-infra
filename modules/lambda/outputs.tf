output "function_name"      { value = local.fn_name }
output "function_arn"       { value = local.fn_arn }
output "invoke_arn"         { value = local.fn_invoke_arn }
output "execution_role_arn" { value = local.execution_role_arn }
output "execution_role_name" {
  value = var.iam_role_create ? aws_iam_role.this[0].name : ""
}
