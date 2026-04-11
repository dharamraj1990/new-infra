#!/usr/bin/env python3
"""
scripts/generate_configs.py

Reads input.yaml → writes one terragrunt.hcl per ENABLED resource.

KEY DESIGN — Smart dependency handling:
  Dependencies are only added when the target resource is ALSO enabled.
  If lambda is disabled but S3 has lambda_trigger enabled → trigger is silently
  skipped (lambda_trigger_enabled = false passed to module). This prevents
  "dependency has no outputs" errors when a referenced resource is not deployed.

  Same logic for: ECR→Lambda, SQS→Lambda, SNS→Lambda, S3→CloudFront.

Single-resource destroy:
  Pass --target=<type>-<name> to generate only that module's manifest entry.
  The destroy workflow reads generated_modules.txt so only that one runs.
"""

import sys, json, yaml, argparse, copy
from pathlib import Path


def hcl_escape(val) -> str:
    """Escape a value for safe embedding in HCL quoted strings."""
    return str(val).replace('\\', '\\\\').replace('"', '\\"')


def to_bool(val, default: bool = False) -> bool:
    """Coerce YAML-parsed values to bool.

    Handles:
      - Python bool (True/False) — from YAML true/false, on/off (unquoted)
      - String "on"/"off"/"true"/"false"/"yes"/"no" — from quoted YAML values
      - None — returns default
    This makes boolean inputs in input.yaml robust against quoting accidents.
    """
    if isinstance(val, bool):
        return val
    if val is None:
        return default
    return str(val).lower() in ("true", "on", "yes", "1")


def merge_env_overlay(base: dict, overlay: dict) -> dict:
    """Deep-merge an environment overlay onto the base input.yaml config.

    Rules:
      - overlay tags:     merged on top of base tags (overlay wins on conflict)
      - overlay resources: matched by type+name; overlay wins per-key for both
                           top-level fields (enabled) and config sub-keys.
                           Resources in the overlay that don't exist in base
                           are silently ignored (they can't be generated without
                           a full definition in base).
    """
    result = copy.deepcopy(base)

    # Merge common tags
    if "tags" in overlay:
        result["tags"] = {**result.get("tags", {}), **overlay["tags"]}

    # Index overlay resources by (type, name) for O(1) lookup
    overlay_map = {
        (r["type"], r["name"]): r
        for r in overlay.get("resources", [])
        if "type" in r and "name" in r
    }

    for i, r in enumerate(result.get("resources", [])):
        key = (r.get("type"), r.get("name"))
        if key not in overlay_map:
            continue
        ov = overlay_map[key]
        # enabled is a top-level field — override if explicitly set
        if "enabled" in ov:
            result["resources"][i]["enabled"] = ov["enabled"]
        # config keys are merged; overlay wins on any key it specifies
        if "config" in ov:
            base_cfg = result["resources"][i].get("config", {})
            result["resources"][i]["config"] = {**base_cfg, **ov["config"]}

    return result


def load_accounts(repo_root):
    accounts_path = Path(repo_root) / "accounts" / "accounts.yaml"
    try:
        with open(accounts_path) as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict):
            print(f"[ERROR] accounts.yaml must be a YAML mapping, got {type(data).__name__}")
            sys.exit(1)
        return data
    except (yaml.YAMLError, FileNotFoundError) as e:
        print(f"[ERROR] Failed to read accounts.yaml: {e}")
        sys.exit(1)


def load_input(path="input.yaml"):
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict):
            print(f"[ERROR] {path} must be a YAML mapping, got {type(data).__name__}")
            sys.exit(1)
        return data
    except (yaml.YAMLError, FileNotFoundError) as e:
        print(f"[ERROR] Failed to read {path}: {e}")
        sys.exit(1)


def resource_dir(repo_root, env, rtype, rname):
    return Path(repo_root) / "live" / env / f"{rtype}-{rname}"


def mock_dep(dep_var, dep_path, mock_outputs: dict):
    """Dependency block — mocks used only for validate/plan/destroy, NEVER apply."""
    lines = "\n".join(f'    {k} = "{hcl_escape(v)}"' for k, v in mock_outputs.items())
    return f"""dependency "{dep_var}" {{
  config_path = "{dep_path}"
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]
  mock_outputs = {{
{lines}
  }}
}}"""


def extra_tags_hcl(cfg: dict, indent: int = 2) -> str:
    """Render per-resource tags from resource config as HCL map input."""
    tags = cfg.get("tags", {})
    if not tags:
        return " " * indent + 'extra_tags = {}'
    pad   = " " * indent
    inner = " " * (indent + 2)
    lines = "\n".join(f'{inner}{k} = "{hcl_escape(v)}"' for k, v in tags.items())
    return f"{pad}extra_tags = {{\n{lines}\n{pad}}}"


def is_enabled(all_resources, rtype, rname):
    """Check if a resource of given type+name is enabled."""
    for r in all_resources:
        if r["type"] == rtype and r["name"] == rname and r.get("enabled", True):
            return True
    return False


# ─────────────────────────────────────────────────────────────────────────────
# S3
# ─────────────────────────────────────────────────────────────────────────────
def gen_s3(r, ctx):
    cfg = r.get("config", {})
    lt  = cfg.get("lambda_trigger", {})
    lt_enabled  = lt.get("enabled", False)
    lambda_name = lt.get("lambda_name", "")

    # Only wire trigger when lambda is also enabled
    trigger_active = lt_enabled and lambda_name and is_enabled(ctx["all_resources"], "lambda", lambda_name)

    dep_block     = ""
    lambda_inputs = ""

    if trigger_active:
        region   = ctx["region"]
        dep_var  = f"lambda_{lambda_name.replace('-','_')}"
        dep_path = f"../lambda-{lambda_name}"
        dep_block = mock_dep(dep_var, dep_path, {
            "function_arn":       f"arn:aws:lambda:{region}:000000000000:function:placeholder",
            "execution_role_arn": "arn:aws:iam::000000000000:role/placeholder",
        })
        events_json = json.dumps(lt.get("events", ["s3:ObjectCreated:*"]))
        lambda_inputs = f"""\
  lambda_trigger_enabled    = true
  lambda_function_arn       = dependency.{dep_var}.outputs.function_arn
  lambda_execution_role_arn = dependency.{dep_var}.outputs.execution_role_arn
  lambda_trigger_events     = {events_json}
  lambda_filter_prefix      = "{hcl_escape(lt.get("filter_prefix",""))}"
  lambda_filter_suffix      = "{hcl_escape(lt.get("filter_suffix",""))}" """
    else:
        lambda_inputs = "  lambda_trigger_enabled = false"

    dep_section = ("\n\n" + dep_block) if dep_block.strip() else ""

    return f"""include "root" {{
  path = find_in_parent_folders()
}}{dep_section}

terraform {{
  source = "${{get_repo_root()}}/modules//s3"
}}

inputs = {{
  name                   = "{r["name"]}"
  bucket_type            = "{hcl_escape(cfg.get("bucket_type","standard"))}"
  versioning             = {str(cfg.get("versioning",True)).lower()}
  force_destroy          = {str(cfg.get("force_destroy",False)).lower()}
  lifecycle_enabled      = {str(cfg.get("lifecycle_enabled",True)).lower()}
  intelligent_tiering    = {str(cfg.get("intelligent_tiering",True)).lower()}
  expiry_days            = {cfg.get("expiry_days",0)}
  encryption             = "{hcl_escape(cfg.get("encryption","AES256"))}"
  kms_key_arn            = "{hcl_escape(cfg.get("kms_key_arn",""))}"
  access_log_bucket_name = "{hcl_escape(cfg.get("access_log_bucket_name",""))}"
  allowed_vpc_ids        = {json.dumps(cfg.get("allowed_vpc_ids",[]))}
{lambda_inputs}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
# SNS
# ─────────────────────────────────────────────────────────────────────────────
def gen_sns(r, ctx):
    cfg  = r.get("config", {})
    subs = cfg.get("subscriptions", [])

    subs_hcl = ""
    if subs:
        items = []
        for s in subs:
            items.append(f"""    {{
      protocol = "{hcl_escape(s["protocol"])}"
      endpoint = "{hcl_escape(s.get("endpoint",""))}"
    }},""")
        subs_hcl = "  subscriptions = [\n" + "\n".join(items) + "\n  ]"

    allowed_role_arns = cfg.get("allowed_role_arns", [])

    return f"""include "root" {{
  path = find_in_parent_folders()
}}

terraform {{
  source = "${{get_repo_root()}}/modules//sns"
}}

inputs = {{
  name                        = "{r["name"]}"
  fifo                        = {str(cfg.get("fifo",False)).lower()}
  content_based_deduplication = {str(cfg.get("content_based_deduplication",False)).lower()}
  display_name                = "{hcl_escape(cfg.get("display_name",""))}"
  kms_key_arn                 = "{hcl_escape(cfg.get("kms_key_arn","alias/aws/sns"))}"
  allowed_role_arns           = {json.dumps(allowed_role_arns)}
{subs_hcl}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
# SQS
# ─────────────────────────────────────────────────────────────────────────────
def gen_sqs(r, ctx):
    cfg = r.get("config", {})
    return f"""include "root" {{
  path = find_in_parent_folders()
}}

terraform {{
  source = "${{get_repo_root()}}/modules//sqs"
}}

inputs = {{
  name                        = "{r["name"]}"
  fifo                        = {str(cfg.get("fifo",False)).lower()}
  content_based_deduplication = {str(cfg.get("content_based_deduplication",False)).lower()}
  high_throughput_fifo        = {str(cfg.get("high_throughput_fifo",False)).lower()}
  visibility_timeout          = {cfg.get("visibility_timeout",30)}
  message_retention           = {cfg.get("message_retention",86400)}
  max_message_size            = {cfg.get("max_message_size",262144)}
  delay_seconds               = {cfg.get("delay_seconds",0)}
  receive_wait_time_seconds   = {cfg.get("receive_wait_time_seconds",0)}
  sqs_managed_sse_enabled     = {str(cfg.get("sqs_managed_sse_enabled",True)).lower()}
  dlq_enabled                 = {str(cfg.get("dlq_enabled",False)).lower()}
  dlq_max_receive_count       = {cfg.get("dlq_max_receive_count",3)}
  dlq_message_retention       = {cfg.get("dlq_message_retention",1209600)}
  kms_key_arn                 = "{hcl_escape(cfg.get("kms_key_arn",""))}"
  kms_data_key_reuse_period   = {cfg.get("kms_data_key_reuse_period",300)}
  allowed_sns_topic_arns      = {json.dumps(cfg.get("allowed_sns_topic_arns",[]))}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
# ECR
# ─────────────────────────────────────────────────────────────────────────────
def gen_ecr(r, ctx):
    cfg = r.get("config", {})
    return f"""include "root" {{
  path = find_in_parent_folders()
}}

terraform {{
  source = "${{get_repo_root()}}/modules//ecr"
}}

inputs = {{
  name                       = "{r["name"]}"
  scan_on_push               = {str(cfg.get("scan_on_push",True)).lower()}
  tag_immutability           = {str(cfg.get("tag_immutability",True)).lower()}
  force_delete               = {str(cfg.get("force_delete",False)).lower()}
  encryption                 = "{hcl_escape(cfg.get("encryption","AES256"))}"
  kms_key_arn                = "{hcl_escape(cfg.get("kms_key_arn",""))}"
  max_image_count            = {cfg.get("max_image_count",10)}
  lambda_integration_enabled = {str(cfg.get("lambda_integration_enabled",False)).lower()}
  allowed_principal_arns     = {json.dumps(cfg.get("allowed_principal_arns",[]))}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
# Lambda
# ─────────────────────────────────────────────────────────────────────────────
def gen_lambda(r, ctx):
    cfg      = r.get("config", {})
    pkg      = cfg.get("package_type", "zip")
    ecr_name = cfg.get("ecr_name", r["name"])
    region   = ctx["region"]

    dep_blocks   = []
    extra_inputs = []

    # Container image_uri resolution:
    #   1. User provides explicit image_uri in config → use it directly (external ECR or any registry)
    #   2. ECR resource is enabled in this stack → wire dependency to get repo URL
    #   3. Neither → error (container Lambda requires an image)
    if pkg == "container":
        explicit_image_uri = cfg.get("image_uri", "")
        image_tag = cfg.get("image_tag", "latest")
        if explicit_image_uri:
            # User provided image_uri directly (external ECR, Docker Hub, etc.)
            extra_inputs.append(f'  image_uri = "{hcl_escape(explicit_image_uri)}"')
        elif is_enabled(ctx["all_resources"], "ecr", ecr_name):
            dep_var  = f"ecr_{ecr_name.replace('-','_')}"
            dep_path = f"../ecr-{ecr_name}"
            dep_blocks.append(mock_dep(dep_var, dep_path, {
                "repository_url": f"000000000000.dkr.ecr.{region}.amazonaws.com/placeholder",
            }))
            extra_inputs.append(
                f'  image_uri = "${{dependency.{dep_var}.outputs.repository_url}}:{hcl_escape(image_tag)}"'
            )
        else:
            print(f"[WARN] Lambda '{r['name']}' is container type but ECR '{ecr_name}' is disabled and no image_uri provided")
            extra_inputs.append(f'  # WARNING: container Lambda requires image_uri — set config.image_uri or enable ECR "{ecr_name}"')

        # Container image config overrides
        image_cmd = cfg.get("image_command", [])
        image_ep  = cfg.get("image_entry_point", [])
        image_wd  = cfg.get("image_working_directory", "")
        if image_cmd:
            extra_inputs.append(f"  image_command         = {json.dumps(image_cmd)}")
        if image_ep:
            extra_inputs.append(f"  image_entry_point     = {json.dumps(image_ep)}")
        if image_wd:
            extra_inputs.append(f'  image_working_directory = "{hcl_escape(image_wd)}"')

    # Zip package — wire filename/source_code_hash if provided
    if pkg == "zip":
        filename = cfg.get("filename", "")
        if filename:
            extra_inputs.append(f'  filename = "{hcl_escape(filename)}"')
        source_hash = cfg.get("source_code_hash", "")
        if source_hash:
            extra_inputs.append(f'  source_code_hash = "{hcl_escape(source_hash)}"')

    # SQS trigger (only if SQS is enabled)
    sqs_cfg = ctx.get("sqs_triggers", {}).get(r["name"])
    if sqs_cfg and is_enabled(ctx["all_resources"], "sqs", sqs_cfg["sqs_name"]):
        sqs_name = sqs_cfg["sqs_name"]
        dep_var  = f"sqs_{sqs_name.replace('-','_')}"
        dep_path = f"../sqs-{sqs_name}"
        dep_blocks.append(mock_dep(dep_var, dep_path, {
            "queue_arn": f"arn:aws:sqs:{region}:000000000000:placeholder",
            "queue_url": f"https://sqs.{region}.amazonaws.com/000000000000/placeholder",
        }))
        extra_inputs.append("  sqs_trigger_enabled = true")
        extra_inputs.append(f"  sqs_queue_arn       = dependency.{dep_var}.outputs.queue_arn")
        extra_inputs.append(f"  sqs_batch_size      = {sqs_cfg.get('batch_size',10)}")
    elif sqs_cfg:
        extra_inputs.append("  sqs_trigger_enabled = false  # SQS disabled")

    # SNS trigger (only if SNS is enabled)
    sns_cfg = ctx.get("sns_triggers", {}).get(r["name"])
    if sns_cfg and is_enabled(ctx["all_resources"], "sns", sns_cfg["sns_name"]):
        sns_name = sns_cfg["sns_name"]
        dep_var  = f"sns_{sns_name.replace('-','_')}"
        dep_path = f"../sns-{sns_name}"
        dep_blocks.append(mock_dep(dep_var, dep_path, {
            "topic_arn": f"arn:aws:sns:{region}:000000000000:placeholder",
        }))
        extra_inputs.append("  sns_trigger_enabled = true")
        extra_inputs.append(f"  sns_topic_arn       = dependency.{dep_var}.outputs.topic_arn")
    elif sns_cfg:
        extra_inputs.append("  sns_trigger_enabled = false  # SNS disabled")

    svc     = json.dumps(cfg.get("service_access", []))
    env_vars = cfg.get("environment_variables", {})
    env_hcl  = "  environment_variables = {}"
    if env_vars:
        items   = "\n".join(f'    {k} = "{hcl_escape(v)}"' for k, v in env_vars.items())
        env_hcl = f"  environment_variables = {{\n{items}\n  }}"

    vpc_inputs = ""
    if cfg.get("vpc_enabled", False):
        vpc_inputs = f"""\
  vpc_id          = "{hcl_escape(cfg.get("vpc_id",""))}"
  subnet_ids      = {json.dumps(cfg.get("subnet_ids",[]))}
  sg_create       = {str(cfg.get("sg_create",True)).lower()}
  existing_sg_ids = {json.dumps(cfg.get("existing_sg_ids",[]))}"""

    # Resource ARN scoping for service_access IAM policies
    arn_inputs = []
    for svc_name, var_name in [
        ("s3", "s3_resource_arns"), ("sqs", "sqs_resource_arns"),
        ("sns", "sns_resource_arns"), ("dynamodb", "dynamodb_resource_arns"),
        ("ssm", "ssm_resource_arns"), ("secretsmanager", "secretsmanager_resource_arns"),
    ]:
        arns = cfg.get(var_name, [])
        if arns:
            arn_inputs.append(f"  {var_name} = {json.dumps(arns)}")

    deps_str = ("\n\n" + "\n\n".join(dep_blocks)) if dep_blocks else ""

    return f"""include "root" {{
  path = find_in_parent_folders()
}}{deps_str}

terraform {{
  source = "${{get_repo_root()}}/modules//lambda"
}}

inputs = {{
  name                = "{r["name"]}"
  package_type        = "{pkg}"
  runtime             = "{cfg.get("runtime","python3.12")}"
  handler             = "{cfg.get("handler","handler.main")}"
  arch                = "{cfg.get("arch","arm64")}"
  timeout             = {cfg.get("timeout",30)}
  memory_size         = {cfg.get("memory",512)}
  log_retention_days  = {cfg.get("log_retention_days",14)}
  iam_role_create     = {str(cfg.get("iam_role_create",True)).lower()}
  iam_role_arn        = "{hcl_escape(cfg.get("iam_role_arn",""))}"
  iam_role_name       = "{hcl_escape(cfg.get("iam_role_name",""))}"
  vpc_enabled         = {str(cfg.get("vpc_enabled",False)).lower()}
  service_access      = {svc}
  permission_boundary = "{hcl_escape(cfg.get("permission_boundary",""))}"
{env_hcl}
{vpc_inputs}
{chr(10).join(extra_inputs)}
{chr(10).join(arn_inputs)}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
# EC2
# ─────────────────────────────────────────────────────────────────────────────
_EC2_VPC_PLACEHOLDERS = {"", "vpc-xxxxxxxxx", "vpc-xxx"}
_EC2_SUBNET_PLACEHOLDERS = {"", "subnet-xxxxxxxxx", "subnet-xxx"}


def gen_ec2(r, ctx):
    cfg = r.get("config", {})

    # ── VPC / subnet validation ────────────────────────────────────────────────
    vpc_id    = cfg.get("vpc_id", "")
    subnet_id = cfg.get("subnet_id", "")
    if vpc_id in _EC2_VPC_PLACEHOLDERS:
        print(f"[ERROR] EC2 '{r['name']}': vpc_id is required — set a real VPC ID (e.g. vpc-0abc1234)")
        sys.exit(1)
    if subnet_id in _EC2_SUBNET_PLACEHOLDERS:
        print(f"[ERROR] EC2 '{r['name']}': subnet_id is required — set a real subnet ID (e.g. subnet-0abc1234)")
        sys.exit(1)

    key_hcl = f"""\
  key_pair_create        = {str(cfg.get("key_pair_create",True)).lower()}
  existing_key_pair_name = "{hcl_escape(cfg.get("existing_key_pair_name",""))}" """

    sg_create       = cfg.get("sg_create", True)
    existing_sg_ids = cfg.get("existing_sg_ids", [])
    sg_hcl = f"""\
  sg_create       = {str(sg_create).lower()}
  existing_sg_ids = {json.dumps(existing_sg_ids)}"""

    ingress = cfg.get("ingress_rules", [])
    ingress_hcl = ""
    if ingress and not sg_create:
        print(f"[WARN] EC2 '{r['name']}': ingress_rules defined but sg_create=false — rules are ignored (applied to existing_sg_ids instead)")
    if ingress and sg_create:
        items = []
        for rule in ingress:
            items.append(f"""    {{
      from_port   = {rule["from_port"]}
      to_port     = {rule["to_port"]}
      protocol    = "{rule["protocol"]}"
      cidr_blocks = {json.dumps(rule.get("cidr_blocks",[]))}
      description = "{hcl_escape(rule.get("description",""))}"
    }},""")
        ingress_hcl = "  ingress_rules = [\n" + "\n".join(items) + "\n  ]"

    ebs_vols = cfg.get("ebs_volumes", [{"device_name":"/dev/xvda","size":30,"type":"gp3"}])
    ebs_items = []
    for v in ebs_vols:
        ebs_items.append(f"""    {{
      device_name = "{v["device_name"]}"
      size        = {v["size"]}
      type        = "{v.get("type","gp3")}"
    }},""")
    ebs_hcl = "  ebs_volumes = [\n" + "\n".join(ebs_items) + "\n  ]"

    iam_hcl = f"""\
  iam_role_create           = {str(cfg.get("iam_role_create",True)).lower()}
  iam_role_name             = "{hcl_escape(cfg.get("iam_role_name",""))}"
  existing_instance_profile = "{hcl_escape(cfg.get("existing_instance_profile",""))}" """

    asg_hcl = f"  asg_enabled = {str(cfg.get('asg_enabled',False)).lower()}"
    if cfg.get("asg_enabled", False):
        asg_hcl += f"""
  asg_desired    = {cfg.get("asg_desired",1)}
  asg_min        = {cfg.get("asg_min",1)}
  asg_max        = {cfg.get("asg_max",3)}
  asg_subnet_ids = {json.dumps(cfg.get("asg_subnet_ids",[]))}"""

    # user_data: multiline scripts need heredoc syntax, not quoted strings
    user_data_raw = cfg.get("user_data", "")
    if user_data_raw:
        user_data_hcl = f"  user_data             = <<-EOT\n{user_data_raw}\n  EOT"
    else:
        user_data_hcl = '  user_data             = ""'

    return f"""include "root" {{
  path = find_in_parent_folders()
}}

terraform {{
  source = "${{get_repo_root()}}/modules//ec2"
}}

inputs = {{
  name           = "{r["name"]}"
  arch           = "{cfg.get("arch","arm64")}"
  os             = "{cfg.get("os","ubuntu")}"
  instance_type  = "{cfg.get("instance_type","t4g.small")}"
  ami            = "{cfg.get("ami","auto")}"
  vpc_id         = "{hcl_escape(vpc_id)}"
  subnet_id      = "{hcl_escape(subnet_id)}"
  imdsv2_enabled = {str(cfg.get("imdsv2_enabled",True)).lower()}
  ebs_encryption = "{hcl_escape(cfg.get("ebs_encryption","default"))}"
  ebs_kms_key_arn= "{hcl_escape(cfg.get("ebs_kms_key_arn",""))}"
{key_hcl}
{sg_hcl}
{ingress_hcl}
{iam_hcl}
{asg_hcl}
{ebs_hcl}
  prometheus_monitoring = {str(to_bool(cfg.get("prometheus_monitoring"), default=False)).lower()}
  argus_monitoring      = {str(to_bool(cfg.get("argus_monitoring"),      default=False)).lower()}
{user_data_hcl}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
# CloudFront
# ─────────────────────────────────────────────────────────────────────────────
def gen_cloudfront(r, ctx):
    cfg     = r.get("config", {})
    origins = cfg.get("origins", [])

    dep_blocks = []
    orig_items = []

    for o in origins:
        domain    = o.get("domain_name", "")
        s3_bucket = o.get("s3_bucket_name", "")
        origin_id = o.get("origin_id", "default")
        otype     = o.get("origin_type", "s3")
        opath     = o.get("origin_path", "")

        if s3_bucket and is_enabled(ctx["all_resources"], "s3", s3_bucket):
            dep_var  = f"s3_{s3_bucket.replace('-','_')}"
            dep_path = f"../s3-{s3_bucket}"
            dep_blocks.append(mock_dep(dep_var, dep_path, {
                "bucket_domain_name": f"placeholder.s3.{ctx['region']}.amazonaws.com",
                "bucket_name":        "placeholder-bucket",
            }))
            domain_val = f"${{dependency.{dep_var}.outputs.bucket_domain_name}}"
        elif s3_bucket:
            # S3 disabled — compute domain from naming convention (name_prefix, not env)
            domain_val = f"{ctx['name_prefix']}-{ctx['region']}-{ctx['project']}-s3-{s3_bucket}.s3.{ctx['region']}.amazonaws.com"
        else:
            domain_val = domain

        orig_items.append(f"""    {{
      domain_name    = "{domain_val}"
      origin_id      = "{origin_id}"
      origin_type    = "{otype}"
      origin_path    = "{opath}"
      custom_headers = []
    }},""")

    origins_hcl = "  origins = [\n" + "\n".join(orig_items) + "\n  ]"
    dep_section = ("\n\n" + "\n\n".join(dep_blocks)) if dep_blocks else ""

    # WAF inputs — supports both flat keys and nested waf: block
    waf_cfg = cfg.get("waf", {})
    waf_enabled = str(cfg.get("waf_enabled", False)).lower()
    waf_create  = str(waf_cfg.get("create", False)).lower()
    waf_acl_id  = waf_cfg.get("waf_web_acl_id", cfg.get("waf_web_acl_id", ""))
    waf_rate_limit_enabled = str(waf_cfg.get("rate_limit_enabled", False)).lower()
    waf_rate_limit = waf_cfg.get("rate_limit", 2000)

    # Cache behaviours
    behaviors     = cfg.get("cache_behaviors", [])
    behaviors_hcl = "  cache_behaviors = []"
    if behaviors:
        items = []
        for b in behaviors:
            items.append(f"""    {{
      path_pattern           = "{b["path_pattern"]}"
      origin_id              = "{b["origin_id"]}"
      viewer_protocol_policy = "{b.get("viewer_protocol_policy","redirect-to-https")}"
      allowed_methods        = {json.dumps(b.get("allowed_methods",["GET","HEAD"]))}
      cached_methods         = {json.dumps(b.get("cached_methods",["GET","HEAD"]))}
      forward_query_strings  = {str(b.get("forward_query_strings",False)).lower()}
      min_ttl                = {b.get("min_ttl",0)}
      default_ttl            = {b.get("default_ttl",86400)}
      max_ttl                = {b.get("max_ttl",31536000)}
    }},""")
        behaviors_hcl = "  cache_behaviors = [\n" + "\n".join(items) + "\n  ]"

    # Geo restriction
    geo_type      = cfg.get("geo_restriction_type", "none")
    geo_locations = json.dumps(cfg.get("geo_restriction_locations", []))

    return f"""include "root" {{
  path = find_in_parent_folders()
}}{dep_section}

terraform {{
  source = "${{get_repo_root()}}/modules//cloudfront"
}}

inputs = {{
  cf_name                = "{r["name"]}"
  price_class            = "{hcl_escape(cfg.get("price_class","PriceClass_All"))}"
  waf_enabled            = {waf_enabled}
  waf_create             = {waf_create}
  waf_web_acl_id         = "{hcl_escape(waf_acl_id)}"
  waf_rate_limit_enabled = {waf_rate_limit_enabled}
  waf_rate_limit         = {waf_rate_limit}
  cache_enabled          = {str(cfg.get("cache_enabled",True)).lower()}
  min_ttl                = {cfg.get("min_ttl",0)}
  default_ttl            = {cfg.get("default_ttl",86400)}
  max_ttl                = {cfg.get("max_ttl",31536000)}
  viewer_protocol_policy = "{hcl_escape(cfg.get("viewer_protocol_policy","redirect-to-https"))}"
  allowed_methods        = {json.dumps(cfg.get("allowed_methods",["GET","HEAD"]))}
  cached_methods         = {json.dumps(cfg.get("cached_methods",["GET","HEAD"]))}
  forward_query_strings  = {str(cfg.get("forward_query_strings",False)).lower()}
  forward_headers        = {json.dumps(cfg.get("forward_headers",[]))}
  forward_cookies        = "{hcl_escape(cfg.get("forward_cookies","none"))}"
  whitelisted_cookie_names = {json.dumps(cfg.get("whitelisted_cookie_names",[]))}
  logging_enabled        = {str(cfg.get("logging_enabled",False)).lower()}
  logging_bucket_name    = "{hcl_escape(cfg.get("logging_bucket_name",""))}"
  logging_include_cookies = {str(cfg.get("logging_include_cookies",False)).lower()}
  geo_restriction_type      = "{hcl_escape(geo_type)}"
  geo_restriction_locations = {geo_locations}
  acm_certificate_arn    = "{hcl_escape(cfg.get("acm_certificate_arn",""))}"
  aliases                = {json.dumps(cfg.get("aliases",[]))}
  default_root_object    = "{hcl_escape(cfg.get("default_root_object","index.html"))}"
{origins_hcl}
{behaviors_hcl}
{extra_tags_hcl(cfg)}
}}
"""


# ─────────────────────────────────────────────────────────────────────────────
GENERATORS = {
    "s3": gen_s3, "sns": gen_sns, "sqs": gen_sqs,
    "ecr": gen_ecr, "lambda": gen_lambda, "ec2": gen_ec2, "cloudfront": gen_cloudfront,
}


def build_trigger_context(all_resources):
    sqs_triggers = {}
    sns_triggers = {}
    for r in all_resources:
        if not r.get("enabled", True):
            continue
        lt = r.get("config", {}).get("lambda_trigger", {})
        if r["type"] == "sqs" and lt.get("enabled") and lt.get("lambda_name"):
            sqs_triggers[lt["lambda_name"]] = {"sqs_name": r["name"], "batch_size": lt.get("batch_size", 10)}
        if r["type"] == "sns" and lt.get("enabled") and lt.get("lambda_name"):
            sns_triggers[lt["lambda_name"]] = {"sns_name": r["name"]}
    return {"sqs_triggers": sqs_triggers, "sns_triggers": sns_triggers}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input_file", nargs="?", default="input.yaml")
    parser.add_argument("repo_root",  nargs="?", default=".")
    parser.add_argument("--account",  default="", help="Account key from accounts/accounts.yaml (e.g. mamstg)")
    parser.add_argument("--target",   default="", help="Only generate/output this resource: type-name (e.g. ec2-api-server)")
    args = parser.parse_args()

    data          = load_input(args.input_file)
    all_resources = data.get("resources", [])
    if not isinstance(all_resources, list):
        print("[ERROR] 'resources' in input.yaml must be a list")
        sys.exit(1)
    for i, r in enumerate(all_resources):
        if not isinstance(r, dict) or "type" not in r or "name" not in r:
            print(f"[ERROR] Resource at index {i} must be a dict with 'type' and 'name' keys")
            sys.exit(1)

    # Account key comes from --account CLI arg (set by CI from workflow dropdown).
    # Falls back to data["account"] for local runs where input.yaml still has the key.
    # accounts.yaml is the single source of truth for all stack metadata.
    account_key = args.account or data.get("account", "")
    if not account_key:
        print("[ERROR] Account key required: pass --account <key> or set 'account:' in input.yaml")
        sys.exit(1)
    accounts    = load_accounts(args.repo_root)
    if account_key not in accounts:
        print(f"[ERROR] Account key '{account_key}' not found in accounts/accounts.yaml")
        sys.exit(1)
    acct        = accounts[account_key]
    env         = acct["environment"]
    region      = acct["region"]
    project     = acct.get("project_name", acct.get("project", ""))
    name_prefix = acct.get("name_prefix", env)

    # Apply environment-specific overlay (envs/<env>.yaml) if it exists.
    # Overlay keys win over base input.yaml on a per-field basis.
    overlay_path = Path(args.repo_root) / "envs" / f"{env}.yaml"
    if overlay_path.exists():
        try:
            with open(overlay_path) as f:
                overlay = yaml.safe_load(f) or {}
            data = merge_env_overlay(data, overlay)
            all_resources = data.get("resources", [])
            print(f"[INFO] Env overlay applied: {overlay_path}")
        except yaml.YAMLError as e:
            print(f"[ERROR] Failed to parse {overlay_path}: {e}")
            sys.exit(1)
    else:
        print(f"[INFO] No env overlay found at {overlay_path} — using base input.yaml only")

    enabled = [r for r in all_resources if r.get("enabled", True)]

    ctx = build_trigger_context(all_resources)
    ctx.update({"env": env, "region": region, "project": project,
                "name_prefix": name_prefix, "all_resources": all_resources})

    # Apply order: dependencies before dependents
    TYPE_ORDER = {"ecr": 0, "sns": 1, "sqs": 2, "lambda": 3, "s3": 4, "ec2": 5, "cloudfront": 6}
    enabled_sorted = sorted(enabled, key=lambda r: TYPE_ORDER.get(r["type"], 99))

    generated = []
    for r in enabled_sorted:
        rtype = r["type"]
        rname = r["name"]
        gen   = GENERATORS.get(rtype)
        if not gen:
            print(f"[SKIP] No generator for type '{rtype}'")
            continue
        out_dir  = resource_dir(args.repo_root, env, rtype, rname)
        out_dir.mkdir(parents=True, exist_ok=True)
        hcl_path = out_dir / "terragrunt.hcl"
        hcl_path.write_text(gen(r, ctx))
        print(f"[OK]  {hcl_path}")
        generated.append(str(hcl_path))

    # --target: write manifest with ONLY the targeted resource
    # Used by single-resource destroy workflow
    if args.target:
        target_matches = [p for p in generated if f"/{args.target}/" in p]
        if not target_matches:
            print(f"[ERROR] --target '{args.target}' not found in enabled resources")
            sys.exit(1)
        manifest_content = "\n".join(target_matches) + "\n"
        print(f"\n[TARGET] Single resource: {args.target}")
    else:
        manifest_content = "\n".join(generated) + "\n"

    manifest = Path(args.repo_root) / "generated_modules.txt"
    manifest.write_text(manifest_content)
    print(f"\n[OK]  {len(generated)} configs written, {len(manifest_content.splitlines())} in manifest → {manifest}")


if __name__ == "__main__":
    main()
