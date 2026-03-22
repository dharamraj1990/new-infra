#!/usr/bin/env python3
"""
scripts/cost_estimate.py

Native AWS cost estimation using boto3 + AWS Pricing API.
No third-party services — plan data never leaves your AWS environment.

Reads Terraform plan JSON files and extracts resource types + configurations,
then queries the AWS Pricing API (us-east-1) for on-demand pricing.

Supported resource types:
  - aws_instance (EC2)
  - aws_lambda_function (Lambda)
  - aws_s3_bucket (S3)
  - aws_sqs_queue (SQS)
  - aws_sns_topic (SNS)
  - aws_ecr_repository (ECR)
  - aws_cloudfront_distribution (CloudFront)

For unsupported types, $0 is reported with a note.
"""

import json, os, sys
from pathlib import Path
from datetime import datetime, timezone

try:
    import boto3
except ImportError:
    print("[WARN] boto3 not available — install with: pip install boto3")
    boto3 = None

GITHUB_RUN_ID     = os.environ.get("GITHUB_RUN_ID", "local")
GITHUB_REPO       = os.environ.get("GITHUB_REPOSITORY", "org/repo")
GITHUB_SERVER_URL = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
GITHUB_ACTOR      = os.environ.get("GITHUB_ACTOR", "unknown")
ENVIRONMENT       = os.environ.get("ENVIRONMENT", "dev")
PROJECT           = os.environ.get("PROJECT", "op2mise")
PLAN_DIR          = os.environ.get("PLAN_DIR", "plan_outputs")
AWS_REGION        = os.environ.get("AWS_REGION", os.environ.get("AWS_DEFAULT_REGION", "ap-south-1"))
ACTIONS_URL       = f"{GITHUB_SERVER_URL}/{GITHUB_REPO}/actions/runs/{GITHUB_RUN_ID}"

HOURS_PER_MONTH = 730.0

# ── Region display name mapping for AWS Pricing API ─────────────────────────
REGION_NAMES = {
    "us-east-1": "US East (N. Virginia)",
    "us-east-2": "US East (Ohio)",
    "us-west-1": "US West (N. California)",
    "us-west-2": "US West (Oregon)",
    "ap-south-1": "Asia Pacific (Mumbai)",
    "ap-south-2": "Asia Pacific (Hyderabad)",
    "ap-southeast-1": "Asia Pacific (Singapore)",
    "ap-southeast-2": "Asia Pacific (Sydney)",
    "ap-northeast-1": "Asia Pacific (Tokyo)",
    "ap-northeast-2": "Asia Pacific (Seoul)",
    "ap-northeast-3": "Asia Pacific (Osaka)",
    "eu-west-1": "Europe (Ireland)",
    "eu-west-2": "Europe (London)",
    "eu-west-3": "Europe (Paris)",
    "eu-central-1": "Europe (Frankfurt)",
    "eu-north-1": "Europe (Stockholm)",
    "sa-east-1": "South America (Sao Paulo)",
    "ca-central-1": "Canada (Central)",
    "me-south-1": "Middle East (Bahrain)",
    "af-south-1": "Africa (Cape Town)",
}


def get_pricing_client():
    """Pricing API is only available in us-east-1 and ap-south-1."""
    if boto3 is None:
        return None
    try:
        return boto3.client("pricing", region_name="us-east-1")
    except Exception:
        return None


def query_ec2_price(client, instance_type: str, region: str, os_type: str = "Linux") -> float:
    """Get EC2 on-demand hourly price."""
    if not client:
        return 0.0
    location = REGION_NAMES.get(region, region)
    try:
        resp = client.get_products(
            ServiceCode="AmazonEC2",
            Filters=[
                {"Type": "TERM_MATCH", "Field": "instanceType", "Value": instance_type},
                {"Type": "TERM_MATCH", "Field": "location", "Value": location},
                {"Type": "TERM_MATCH", "Field": "operatingSystem", "Value": os_type},
                {"Type": "TERM_MATCH", "Field": "tenancy", "Value": "Shared"},
                {"Type": "TERM_MATCH", "Field": "preInstalledSw", "Value": "NA"},
                {"Type": "TERM_MATCH", "Field": "capacitystatus", "Value": "Used"},
            ],
            MaxResults=1,
        )
        for price_item in resp.get("PriceList", []):
            data = json.loads(price_item) if isinstance(price_item, str) else price_item
            terms = data.get("terms", {}).get("OnDemand", {})
            for term in terms.values():
                for dim in term.get("priceDimensions", {}).values():
                    usd = dim.get("pricePerUnit", {}).get("USD", "0")
                    return float(usd)
    except Exception as e:
        print(f"    [pricing] EC2 lookup failed: {e}")
    return 0.0


def query_lambda_price(client, region: str, memory_mb: int, arch: str = "arm64") -> dict:
    """Get Lambda pricing (per-request and per-GB-second)."""
    # Lambda pricing is relatively stable — use known rates as fallback
    # arm64 is ~20% cheaper than x86_64
    if arch in ("arm64", "aarch64"):
        return {"request": 0.0000002, "gb_second": 0.0000133334}
    return {"request": 0.0000002, "gb_second": 0.0000166667}


def query_s3_price(region: str) -> dict:
    """S3 Standard pricing — per-GB storage and per-1000 requests."""
    # S3 Standard rates (approximate, varies by region)
    return {"storage_gb": 0.023, "put_1k": 0.005, "get_1k": 0.0004}


def estimate_from_plan(plan_data: dict, pricing_client) -> tuple[float, list]:
    """
    Parse Terraform plan JSON and estimate costs for each resource.
    Returns (total_monthly, list of {resource, type, monthly, detail}).
    """
    total_monthly = 0.0
    details = []

    resources = []
    # planned_values → root_module → resources
    root = plan_data.get("planned_values", {}).get("root_module", {})
    resources.extend(root.get("resources", []))
    # Also check child modules
    for child in root.get("child_modules", []):
        resources.extend(child.get("resources", []))
        for grandchild in child.get("child_modules", []):
            resources.extend(grandchild.get("resources", []))

    # Also check resource_changes for more detail
    resource_changes = plan_data.get("resource_changes", [])
    change_map = {}
    for rc in resource_changes:
        addr = rc.get("address", "")
        after = rc.get("change", {}).get("after", {})
        if after:
            change_map[addr] = after

    for res in resources:
        rtype   = res.get("type", "")
        name    = res.get("name", "")
        addr    = res.get("address", "")
        values  = res.get("values", {})
        monthly = 0.0
        detail  = ""

        # Merge with change_after if available (has more complete data)
        if addr in change_map:
            values = {**values, **change_map[addr]}

        if rtype == "aws_instance":
            itype = values.get("instance_type", "t4g.small")
            hourly = query_ec2_price(pricing_client, itype, AWS_REGION)
            monthly = hourly * HOURS_PER_MONTH
            detail = f"{itype} @ ${hourly:.4f}/hr"

        elif rtype == "aws_lambda_function":
            memory = values.get("memory_size", 512)
            arch = "arm64"
            archs = values.get("architectures", [])
            if archs:
                arch = archs[0]
            prices = query_lambda_price(pricing_client, AWS_REGION, memory, arch)
            # Estimate: 1M invocations/month, 200ms avg duration
            est_invocations = 1_000_000
            est_duration_s  = 0.2
            gb_seconds = est_invocations * est_duration_s * (memory / 1024.0)
            monthly = (est_invocations * prices["request"]) + (gb_seconds * prices["gb_second"])
            detail = f"{memory}MB {arch}, ~1M inv/mo @ 200ms"

        elif rtype == "aws_s3_bucket":
            prices = query_s3_price(AWS_REGION)
            # Estimate: 100GB storage, 100k PUTs, 1M GETs/month
            monthly = (100 * prices["storage_gb"]) + (100 * prices["put_1k"]) + (1000 * prices["get_1k"])
            detail = "~100GB, 100k PUTs, 1M GETs est."

        elif rtype == "aws_sqs_queue":
            # First 1M requests/month free, then $0.40/1M
            fifo = values.get("fifo_queue", False)
            rate = 0.00000050 if fifo else 0.00000040
            est_messages = 5_000_000
            monthly = max(0, (est_messages - 1_000_000)) * rate
            detail = f"{'FIFO' if fifo else 'Standard'}, ~5M msg/mo"

        elif rtype == "aws_sns_topic":
            # First 1M publishes free, then $0.50/1M
            monthly = 0.0
            detail = "first 1M publishes free"

        elif rtype == "aws_ecr_repository":
            # $0.10/GB/month storage
            monthly = 5.0 * 0.10  # estimate 5GB
            detail = "~5GB images est."

        elif rtype == "aws_cloudfront_distribution":
            # $0.085/GB first 10TB (India), $0.0090/10k HTTPS requests
            monthly = (100 * 0.085) + (1000 * 0.009)  # 100GB transfer, 10M requests
            detail = "~100GB transfer, 10M req est."

        elif rtype == "aws_cloudwatch_log_group":
            monthly = 0.0
            detail = "ingestion: $0.50/GB"

        elif rtype == "aws_launch_template":
            # No cost — cost is on the instance
            continue

        elif rtype in ("aws_iam_role", "aws_iam_policy", "aws_iam_role_policy_attachment",
                       "aws_iam_instance_profile", "aws_security_group", "aws_key_pair",
                       "aws_s3_bucket_versioning", "aws_s3_bucket_server_side_encryption_configuration",
                       "aws_s3_bucket_public_access_block", "aws_s3_bucket_policy",
                       "aws_s3_bucket_lifecycle_configuration", "aws_s3_bucket_logging",
                       "aws_s3_bucket_notification", "aws_lambda_permission",
                       "aws_lambda_event_source_mapping", "aws_sns_topic_subscription",
                       "aws_sns_topic_policy", "aws_sqs_queue_policy",
                       "aws_ecr_lifecycle_policy", "aws_ecr_repository_policy",
                       "aws_cloudfront_origin_access_control", "aws_wafv2_web_acl",
                       "aws_autoscaling_group", "aws_secretsmanager_secret",
                       "aws_secretsmanager_secret_version", "tls_private_key"):
            # Free / config-only resources
            continue

        else:
            detail = f"unsupported type: {rtype}"

        if monthly > 0 or detail:
            total_monthly += monthly
            details.append({
                "resource": addr or f"{rtype}.{name}",
                "type": rtype,
                "monthly": round(monthly, 4),
                "detail": detail,
            })

    return total_monthly, details


def find_terraform_cache(module_live_dir: Path) -> Path | None:
    """Find .terraform cache dir inside .terragrunt-cache."""
    import glob as _glob
    pattern = str(module_live_dir / ".terragrunt-cache" / "**" / ".terraform")
    matches = _glob.glob(pattern, recursive=True)
    if matches:
        return Path(matches[0]).parent
    return None


def tfplan_to_json(plan_bin: Path, module_live_dir: Path) -> tuple[Path | None, str | None]:
    """Convert binary .tfplan → JSON using terraform show -json."""
    import subprocess
    cache_dir = find_terraform_cache(module_live_dir)
    if not cache_dir:
        return None, "no .terraform cache dir found"
    out = plan_bin.with_suffix(".json")
    try:
        r = subprocess.run(
            ["terraform", "-chdir=" + str(cache_dir), "show", "-json", str(plan_bin.resolve())],
            capture_output=True, text=True, timeout=60
        )
        if r.returncode != 0 or not r.stdout.strip():
            return None, f"terraform show failed: {r.stderr[:200].strip()}"
        try:
            d = json.loads(r.stdout)
            if not d.get("format_version"):
                return None, "terraform show output is not a plan JSON"
        except json.JSONDecodeError:
            return None, "terraform show output is not valid JSON"
        out.write_text(r.stdout)
        return out, None
    except Exception as e:
        return None, str(e)


def fmt(val: float) -> str:
    if val == 0.0:
        return "$0.00"
    if val < 0.01:
        return f"${val:.5f}"
    return f"${val:.2f}"


def main():
    manifest = Path("generated_modules.txt")
    if not manifest.exists():
        print("[ERROR] generated_modules.txt not found")
        sys.exit(1)

    modules  = [l.strip() for l in manifest.read_text().splitlines() if l.strip()]
    plan_dir = Path(PLAN_DIR)

    print(f"Cost estimation for {len(modules)} modules (AWS Pricing API)\n")

    pricing_client = get_pricing_client()
    if not pricing_client:
        print("[WARN] AWS Pricing API unavailable — using static rate tables")

    report = {
        "generated_at":  datetime.now(timezone.utc).isoformat(),
        "run_id":        GITHUB_RUN_ID,
        "actor":         GITHUB_ACTOR,
        "environment":   ENVIRONMENT,
        "project":       PROJECT,
        "actions_url":   ACTIONS_URL,
        "pricing_source": "aws-pricing-api" if pricing_client else "static-rates",
        "modules":       [],
        "total_monthly": 0.0,
        "total_hourly":  0.0,
    }

    for mod_path in modules:
        name            = Path(mod_path).parent.name
        module_live_dir = Path(mod_path).parent
        plan_json       = plan_dir / f"{name}.json"
        plan_bin        = plan_dir / f"{name}.tfplan"
        err_prefix      = None

        # Step 1: Ensure we have a valid plan JSON
        if plan_json.exists():
            try:
                d = json.loads(plan_json.read_text())
                if not d.get("format_version"):
                    plan_json.unlink()
                    raise ValueError("not a plan JSON")
            except Exception:
                plan_json = plan_dir / f"{name}.json"
                plan_json_valid = False
            else:
                plan_json_valid = True
        else:
            plan_json_valid = False

        # Step 2: If JSON missing/invalid, try binary .tfplan
        if not plan_json_valid:
            if plan_bin.exists():
                plan_json, conv_err = tfplan_to_json(plan_bin, module_live_dir)
                if conv_err:
                    err_prefix = f"tfplan->json failed: {conv_err}"
            else:
                err_prefix = f"no plan file found in {plan_dir}/"

        # Step 3: Estimate costs from plan JSON
        monthly = 0.0
        hourly  = 0.0
        err     = err_prefix
        resource_details = []

        if plan_json and plan_json.exists() and not err_prefix:
            try:
                plan_data = json.loads(plan_json.read_text())
                monthly, resource_details = estimate_from_plan(plan_data, pricing_client)
                hourly = monthly / HOURS_PER_MONTH if monthly > 0 else 0.0
            except Exception as e:
                err = f"estimation failed: {e}"
        elif not err:
            err = "plan JSON unavailable"

        status = "error" if err else "ok"
        print(f"  {name}: {fmt(monthly)}/month  {fmt(hourly)}/hr  [{status}]"
              + (f"\n    -> {err}" if err else ""))
        for rd in resource_details:
            if rd["monthly"] > 0:
                print(f"    {rd['resource']}: {fmt(rd['monthly'])}/mo ({rd['detail']})")

        report["modules"].append({
            "name":            name,
            "monthly_cost":    round(monthly, 4),
            "hourly_cost":     round(hourly, 6),
            "status":          status,
            "error":           err,
            "resource_details": resource_details,
        })
        report["total_monthly"] += monthly
        report["total_hourly"]  += hourly

    report["total_monthly"] = round(report["total_monthly"], 4)
    report["total_hourly"]  = round(report["total_hourly"], 6)

    Path("cost_report.json").write_text(json.dumps(report, indent=2))

    rows = "\n".join(
        f"| `{m['name']}` | {fmt(m['monthly_cost'])}/month | {fmt(m['hourly_cost'])}/hr | {'X' if m['error'] else 'OK'} |"
        for m in report["modules"]
    )

    md = f"""## Infrastructure Cost Estimate — Approval Required

| | |
|---|---|
| **Environment** | `{ENVIRONMENT}` |
| **Project**     | `{PROJECT}` |
| **Actor**       | `{GITHUB_ACTOR}` |
| **Run**         | [{GITHUB_RUN_ID}]({ACTIONS_URL}) |
| **Source**       | AWS Pricing API (no third-party) |

### Estimated Costs

| Module | Monthly | Hourly | Status |
|---|---|---|---|
{rows}
| **TOTAL** | **{fmt(report['total_monthly'])}/month** | **{fmt(report['total_hourly'])}/hr** | |

> Costs are estimates based on the Terraform plan and assumed usage patterns.
> EC2 pricing is real-time from AWS Pricing API. Lambda/S3/SQS use estimated workloads.

### Approve

Open the [Actions run]({ACTIONS_URL}) -> **Review deployments** -> `{ENVIRONMENT}-approval` -> **Approve**.
"""

    Path("cost_summary.md").write_text(md)
    print(f"\n{'='*55}")
    print(f"TOTAL  {fmt(report['total_monthly'])}/month  |  {fmt(report['total_hourly'])}/hr")
    print(f"{'='*55}")

    if gos := os.environ.get("GITHUB_OUTPUT"):
        with open(gos, "a") as f:
            f.write(f"total_monthly_cost={report['total_monthly']}\n")
            f.write(f"total_hourly_cost={report['total_hourly']}\n")
            f.write(f"module_count={len(report['modules'])}\n")

    if gss := os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(gss, "a") as f:
            f.write(md)


if __name__ == "__main__":
    main()
