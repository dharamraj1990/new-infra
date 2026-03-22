include "root" {
  path = find_in_parent_folders()
}

terraform {
  source = "${get_repo_root()}/modules//ec2"
}

inputs = {
  name           = "api-server"
  arch           = "arm64"
  os             = "ubuntu"
  instance_type  = "t4g.small"
  ami            = "auto"
  vpc_id         = ""
  subnet_id      = ""
  imdsv2_enabled = true
  ebs_encryption = "default"
  ebs_kms_key_arn= ""
  key_pair_create        = true
  existing_key_pair_name = "" 
  sg_create       = true
  existing_sg_ids = []
  ingress_rules = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["10.0.0.0/8"]
      description = "SSH from VPN"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "HTTPS"
    },
  ]
  iam_role_create           = true
  iam_role_name             = ""
  existing_instance_profile = "" 
  asg_enabled = false
  ebs_volumes = [
    {
      device_name = "/dev/xvda"
      size        = 30
      type        = "gp3"
    },
  ]
  prometheus_monitoring = true
  argus_monitoring      = false
  extra_tags = {
    Component = "api"
    Application = "order-service"
  }
}
