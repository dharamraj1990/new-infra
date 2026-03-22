#!/usr/bin/env python3
"""
scripts/cost_estimate.py

Pricing strategy (in priority order):
  1. Use plan_outputs/<n>.json (terraform plan JSON) if it exists and is valid
  2. Use plan_outputs/<n>.tfplan binary — locate the .terraform cache dir
     and run terraform show -json from it
  3. Skip the module and record $0 with an error note

Infracost is called with --path <plan.json> --format json.
Monthly AND hourly costs are shown in the report.
"""

import json, os, subprocess, sys, glob
from pathlib import Path
from datetime import datetime, timezone

GITHUB_RUN_ID     = os.environ.get("GITHUB_RUN_ID", "local")
GITHUB_REPO       = os.environ.get("GITHUB_REPOSITORY", "org/repo")
GITHUB_SERVER_URL = os.environ.get("GITHUB_SERVER_URL", "https://github.com")
GITHUB_ACTOR      = os.environ.get("GITHUB_ACTOR", "unknown")
ENVIRONMENT       = os.environ.get("ENVIRONMENT", "dev")
PROJECT           = os.environ.get("PROJECT", "op2mise")
INFRACOST_KEY     = os.environ.get("INFRACOST_API_KEY", "")
PLAN_DIR          = os.environ.get("PLAN_DIR", "plan_outputs")
ACTIONS_URL       = f"{GITHUB_SERVER_URL}/{GITHUB_REPO}/actions/runs/{GITHUB_RUN_ID}"


def find_terraform_cache(module_live_dir: Path) -> Path | None:
    """
    Find the dir inside .terragrunt-cache that contains .terraform/.
    Terragrunt cache structure:
      <module>/.terragrunt-cache/<hash1>/<hash2>/<module-name>/.terraform/
    We search up to depth 7 for .terraform dirs.
    """
    pattern = str(module_live_dir / ".terragrunt-cache" / "**" / ".terraform")
    matches = glob.glob(pattern, recursive=True)
    if matches:
        return Path(matches[0]).parent
    return None


def tfplan_to_json(plan_bin: Path, module_live_dir: Path) -> tuple[Path | None, str | None]:
    """Convert binary .tfplan → JSON using terraform show -json."""
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
        # Validate it's real plan JSON
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


def infracost_breakdown(plan_json_path: Path) -> tuple[float, float, str | None]:
    """
    Run infracost breakdown on a terraform plan JSON.
    Returns (monthly_cost, hourly_cost, error_or_None).
    """
    env = {**os.environ}
    if INFRACOST_KEY:
        env["INFRACOST_API_KEY"] = INFRACOST_KEY

    try:
        r = subprocess.run(
            ["infracost", "breakdown",
             "--path", str(plan_json_path),
             "--format", "json",
             "--no-color"],
            capture_output=True, text=True, timeout=120, env=env
        )
    except FileNotFoundError:
        return 0.0, 0.0, "infracost not installed"
    except subprocess.TimeoutExpired:
        return 0.0, 0.0, "infracost timed out"
    except Exception as e:
        return 0.0, 0.0, str(e)

    if r.returncode != 0:
        return 0.0, 0.0, f"infracost exit {r.returncode}: {r.stderr.strip()[:200]}"

    if not r.stdout.strip():
        return 0.0, 0.0, "infracost empty output"

    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        return 0.0, 0.0, f"infracost JSON parse: {e}"

    # Extract cost — infracost puts summary at top level AND inside projects[]
    def parse_cost(raw):
        try:
            return float(raw) if raw is not None else 0.0
        except (ValueError, TypeError):
            return 0.0

    monthly = parse_cost(data.get("totalMonthlyCost"))
    hourly  = parse_cost(data.get("totalHourlyCost"))

    # Also try projects array in case top-level is missing
    if monthly == 0.0:
        for proj in data.get("projects", []):
            bd = proj.get("breakdown", {})
            m  = parse_cost(bd.get("totalMonthlyCost"))
            h  = parse_cost(bd.get("totalHourlyCost"))
            monthly += m
            hourly  += h

    if hourly == 0.0 and monthly > 0.0:
        hourly = monthly / 730.0

    return monthly, hourly, None


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

    print(f"Cost estimation for {len(modules)} modules\n")

    report = {
        "generated_at":  datetime.now(timezone.utc).isoformat(),
        "run_id":        GITHUB_RUN_ID,
        "actor":         GITHUB_ACTOR,
        "environment":   ENVIRONMENT,
        "project":       PROJECT,
        "actions_url":   ACTIONS_URL,
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
            # Validate it's real plan JSON (not a terraform error message)
            try:
                d = json.loads(plan_json.read_text())
                if not d.get("format_version"):
                    plan_json.unlink()
                    raise ValueError("not a plan JSON")
            except Exception:
                plan_json = plan_dir / f"{name}.json"  # reset
                plan_json_valid = False
            else:
                plan_json_valid = True
        else:
            plan_json_valid = False

        # Step 2: If JSON missing/invalid, try to generate from binary .tfplan
        if not plan_json_valid:
            if plan_bin.exists():
                plan_json, conv_err = tfplan_to_json(plan_bin, module_live_dir)
                if conv_err:
                    err_prefix = f"tfplan→json failed: {conv_err}"
            else:
                err_prefix = f"no plan file found in {plan_dir}/"

        # Step 3: Run infracost
        if plan_json and plan_json.exists() and not err_prefix:
            monthly, hourly, inf_err = infracost_breakdown(plan_json)
            err = inf_err
        elif err_prefix:
            monthly, hourly, err = 0.0, 0.0, err_prefix
        else:
            monthly, hourly, err = 0.0, 0.0, "plan JSON unavailable"

        status = "error" if err else "ok"
        print(f"  {name}: {fmt(monthly)}/month  {fmt(hourly)}/hr  [{status}]"
              + (f"\n    → {err}" if err else ""))

        report["modules"].append({
            "name":         name,
            "monthly_cost": round(monthly, 4),
            "hourly_cost":  round(hourly, 6),
            "status":       status,
            "error":        err,
        })
        report["total_monthly"] += monthly
        report["total_hourly"]  += hourly

    report["total_monthly"] = round(report["total_monthly"], 4)
    report["total_hourly"]  = round(report["total_hourly"], 6)

    Path("cost_report.json").write_text(json.dumps(report, indent=2))

    rows = "\n".join(
        f"| `{m['name']}` | {fmt(m['monthly_cost'])}/month | {fmt(m['hourly_cost'])}/hr | {'❌' if m['error'] else '✅'} |"
        for m in report["modules"]
    )

    md = f"""## Infrastructure Cost Estimate — Approval Required

| | |
|---|---|
| **Environment** | `{ENVIRONMENT}` |
| **Project**     | `{PROJECT}` |
| **Actor**       | `{GITHUB_ACTOR}` |
| **Run**         | [{GITHUB_RUN_ID}]({ACTIONS_URL}) |

### Estimated Costs

| Module | Monthly | Hourly | Status |
|---|---|---|---|
{rows}
| **TOTAL** | **{fmt(report['total_monthly'])}/month** | **{fmt(report['total_hourly'])}/hr** | |

> Costs are estimates based on the Terraform plan. Actual costs may vary by usage.

### Approve

Open the [Actions run]({ACTIONS_URL}) → **Review deployments** → `{ENVIRONMENT}-approval` → **Approve**.
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
