# modules/ec2/main.tf

locals {
  resource_name = "${var.name_prefix}-${var.aws_region}-${var.project_name}-ec2-${var.name}"

  # Base tags applied to ALL resources in this module (SM secret, SG, IAM role, etc.)
  # Monitoring tags are intentionally excluded here — they are EC2-instance-only.
  tags = merge(var.common_tags, var.extra_tags, {
    Name   = local.resource_name
    Module = "ec2"
    OS     = var.os
    Arch   = var.arch
  })

  # Instance-only tags — applied exclusively via tag_specifications on the launch template.
  # These propagate to EC2 instances and their volumes (not to SM, SG, IAM, ENI, etc.)
  # Values are "on"/"off" strings — discovery scrapers expect these exact strings,
  # not "true"/"false" which tostring(bool) would produce.
  instance_tags = merge(local.tags, {
    PrometheusMonitoring = var.prometheus_monitoring ? "on" : "off"
    ArgusMonitoring      = var.argus_monitoring ? "on" : "off"
  })

  ami_owners = {
    ubuntu       = "099720109477"
    amazon_linux = "137112412989"
  }

  ami_filters = {
    ubuntu_arm64        = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-arm64-server-*"
    ubuntu_x86_64       = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    amazon_linux_arm64  = "al2023-ami-2023.*-kernel-6.1-arm64"
    amazon_linux_x86_64 = "al2023-ami-2023.*-kernel-6.1-x86_64"
  }
}

# ── AMI lookup ────────────────────────────────────────────────────────────────
data "aws_ami" "auto" {
  count       = var.ami == "auto" ? 1 : 0
  most_recent = true
  owners      = [local.ami_owners[var.os]]

  filter {
    name   = "name"
    values = [local.ami_filters["${var.os}_${var.arch}"]]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  resolved_ami = var.ami == "auto" ? data.aws_ami.auto[0].id : var.ami
}

# ── Key pair ──────────────────────────────────────────────────────────────────
# ED25519 is smaller, faster, and equally secure to RSA-4096.
# Supported by AWS EC2 and all modern AMIs (Ubuntu 20.04+, AL2023).
resource "tls_private_key" "this" {
  count     = var.key_pair_create ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  count    = var.key_pair_create ? 1 : 0
  # key_name is fixed so Terraform can track it in state.
  # If the key already exists from a previous run that lost state,
  # import it: terraform import aws_key_pair.this[0] <key-name>
  key_name   = "${local.resource_name}-key"
  public_key = tls_private_key.this[0].public_key_openssh
  tags       = local.tags
}

# Store private key in Secrets Manager
# If secret already exists (e.g. scheduled for deletion), restore it first:
#   aws secretsmanager restore-secret --secret-id <name>
resource "aws_secretsmanager_secret" "private_key" {
  # checkov:skip=CKV_AWS_149:Secret is encrypted using either the provided customer-managed CMK (secrets_manager_kms_key_arn) or the AWS managed key (alias/aws/secretsmanager). Both provide encryption-at-rest. CMK is required only for compliance regimes (PCI-DSS, FedRAMP) — set secrets_manager_kms_key_arn in input.yaml when that is needed.
  # checkov:skip=CKV2_AWS_57:EC2 SSH keypairs are static by nature — rotation means generating a new ED25519 keypair and replacing it on running instances, which is an operational runbook, not an SM lambda rotation.
  count                   = var.key_pair_create ? 1 : 0
  name                    = "${local.resource_name}-private-key"
  description             = "EC2 private key for ${local.resource_name}"
  recovery_window_in_days = 7
  kms_key_id              = var.secrets_manager_kms_key_arn != "" ? var.secrets_manager_kms_key_arn : "alias/aws/secretsmanager"
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "private_key" {
  count         = var.key_pair_create ? 1 : 0
  secret_id     = aws_secretsmanager_secret.private_key[0].id
  secret_string = tls_private_key.this[0].private_key_pem
}

locals {
  key_name = var.key_pair_create ? aws_key_pair.this[0].key_name : var.existing_key_pair_name
}

# ── Security group ────────────────────────────────────────────────────────────
resource "aws_security_group" "this" {
  # checkov:skip=CKV2_AWS_5:SG is attached via the launch_template network_interfaces block. Static analysis cannot resolve this reference across resources.
  count       = var.sg_create ? 1 : 0
  name        = "${local.resource_name}-sg"
  description = "Security group for ${local.resource_name}"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.ingress_rules
    content {
      from_port   = ingress.value.from_port
      to_port     = ingress.value.to_port
      protocol    = ingress.value.protocol
      cidr_blocks = ingress.value.cidr_blocks
      description = ingress.value.description
    }
  }

  # Explicit egress — default is HTTPS+DNS only (not 0.0.0.0/0 to all ports).
  # Override via egress_rules in input.yaml if the workload needs broader outbound.
  dynamic "egress" {
    for_each = var.egress_rules
    content {
      from_port   = egress.value.from_port
      to_port     = egress.value.to_port
      protocol    = egress.value.protocol
      cidr_blocks = egress.value.cidr_blocks
      description = egress.value.description
    }
  }

  tags = merge(local.tags, { Name = "${local.resource_name}-sg" })

  lifecycle {
    # If SG already exists from a prior run, prevent error by creating new before destroy
    create_before_destroy = true
  }
}

locals {
  sg_ids = concat(
    var.sg_create ? [aws_security_group.this[0].id] : [],
    var.existing_sg_ids
  )
}

# ── IAM role + instance profile ───────────────────────────────────────────────
resource "aws_iam_role" "this" {
  count = var.iam_role_create ? 1 : 0
  name  = var.iam_role_name != "" ? var.iam_role_name : "${local.resource_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.iam_role_create ? 1 : 0
  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "this" {
  count = var.iam_role_create ? 1 : 0
  name  = "${local.resource_name}-profile"
  role  = aws_iam_role.this[0].name
  tags  = local.tags
}

locals {
  instance_profile = var.iam_role_create ? aws_iam_instance_profile.this[0].name : var.existing_instance_profile
}

# ── Launch template ───────────────────────────────────────────────────────────
resource "aws_launch_template" "this" {
  # name_prefix avoids conflicts if template already exists from a prior run
  name_prefix            = "${local.resource_name}-lt-"
  image_id               = local.resolved_ami
  instance_type          = var.instance_type
  key_name               = local.key_name
  ebs_optimized          = true   # dedicated EBS throughput, no extra cost on most modern instances

  # Detailed CloudWatch monitoring (1-min granularity vs 5-min default)
  monitoring {
    enabled = true
  }

  # IMDSv2 enforced — prevents SSRF-based metadata exfiltration (e.g. CVE-2019-11253)
  # hop_limit=1 blocks container-to-host credential theft
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # always enforce IMDSv2
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"    # allows EC2 tags in user-data
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = local.sg_ids
    subnet_id                   = var.asg_enabled ? null : var.subnet_id
    delete_on_termination       = true
  }

  iam_instance_profile {
    name = local.instance_profile
  }

  dynamic "block_device_mappings" {
    for_each = var.ebs_volumes
    content {
      device_name = block_device_mappings.value.device_name
      ebs {
        volume_size           = block_device_mappings.value.size
        volume_type           = block_device_mappings.value.type
        encrypted             = true   # always — encryption at rest is non-negotiable
        kms_key_id            = var.ebs_encryption == "kms" && var.ebs_kms_key_arn != "" ? var.ebs_kms_key_arn : null
        delete_on_termination = true
        throughput            = block_device_mappings.value.type == "gp3" ? 125 : null
      }
    }
  }

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  # instance_tags includes PrometheusMonitoring/ArgusMonitoring — these propagate
  # only to the EC2 instance, its EBS volumes, and its ENI via tag_specifications.
  # The launch template resource itself gets local.tags (no monitoring tags).
  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags   # EBS volumes do NOT need monitoring discovery tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.tags   # ENIs do NOT need monitoring discovery tags
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ── Standalone instance ───────────────────────────────────────────────────────
resource "aws_instance" "this" {
  # checkov:skip=CKV_AWS_135:ebs_optimized is set in the launch_template — Checkov cannot follow launch template inheritance on aws_instance resources.
  # checkov:skip=CKV_AWS_126:Detailed monitoring (1-min metrics) is enabled in the launch_template monitoring block.
  # checkov:skip=CKV_AWS_8:EBS encryption is enforced in the launch_template block_device_mappings (encrypted=true on every volume).
  # checkov:skip=CKV_AWS_79:IMDSv2 (http_tokens=required) is enforced in the launch_template metadata_options block.
  # checkov:skip=CKV2_AWS_41:IAM instance profile is set in launch_template iam_instance_profile block — static analysis cannot resolve this.
  count = var.asg_enabled ? 0 : 1

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  subnet_id = var.subnet_id
  tags      = local.tags

  lifecycle {
    # Prevent replacement when Terraform detects a newer AMI — update via launch template refresh
    ignore_changes = [ami, launch_template]

    precondition {
      condition     = var.subnet_id != ""
      error_message = "subnet_id is required for standalone instances (asg_enabled=false)."
    }

    postcondition {
      condition     = self.metadata_options[0].http_tokens == "required"
      error_message = "IMDSv2 (http_tokens=required) must always be enforced on EC2 instances."
    }
  }
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "this" {
  count               = var.asg_enabled ? 1 : 0
  name                = "${local.resource_name}-asg"
  desired_capacity    = var.asg_desired
  min_size            = var.asg_min
  max_size            = var.asg_max
  vpc_zone_identifier = var.asg_subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  dynamic "tag" {
    for_each = local.instance_tags   # propagate monitoring tags to ASG-launched instances
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}
