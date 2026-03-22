# modules/ec2/main.tf

locals {
  resource_name = "${var.name_prefix}-${var.aws_region}-${var.project_name}-ec2-${var.name}"

  tags = merge(var.common_tags, var.extra_tags, {
    Name                  = local.resource_name
    Module                = "ec2"
    OS                    = var.os
    Arch                  = var.arch
    # Monitoring discovery tags — read by Prometheus/Argus scraping agents
    PrometheusMonitoring  = tostring(var.prometheus_monitoring)
    ArgusMonitoring       = tostring(var.argus_monitoring)
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
resource "tls_private_key" "this" {
  count     = var.key_pair_create ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
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
  count                   = var.key_pair_create ? 1 : 0
  name                    = "${local.resource_name}-private-key"
  description             = "EC2 private key for ${local.resource_name}"
  recovery_window_in_days = 7
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
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
  name_prefix   = "${local.resource_name}-lt-"
  image_id      = local.resolved_ami
  instance_type = var.instance_type
  key_name      = local.key_name

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = var.imdsv2_enabled ? "required" : "optional"
    http_put_response_hop_limit = 1
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
        encrypted             = true
        kms_key_id            = var.ebs_encryption == "kms" && var.ebs_kms_key_arn != "" ? var.ebs_kms_key_arn : null
        delete_on_termination = true
      }
    }
  }

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.tags
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
    # NOTE: latest_version is provider-computed and cannot be ignored.
    # Using name_prefix instead of name prevents duplicate conflicts on re-run.
  }
}

# ── Standalone instance ───────────────────────────────────────────────────────
resource "aws_instance" "this" {
  count = var.asg_enabled ? 0 : 1

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  subnet_id = var.subnet_id
  tags      = local.tags

  lifecycle {
    # Prevent destroy when Terraform detects a new AMI or launch template version
    ignore_changes = [ami, launch_template]
    precondition {
      condition     = var.subnet_id != ""
      error_message = "subnet_id is required for standalone instances (asg_enabled=false)."
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
    for_each = local.tags
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
