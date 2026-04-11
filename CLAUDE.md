# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Multi-account AWS infrastructure framework using **Terragrunt + Terraform** with **GitHub Actions OIDC** for keyless auth. `input.yaml` declares the base resource set; per-environment `envs/<env>.yaml` files overlay environment-specific values. The Python code-generator merges them and produces per-resource Terragrunt configs under `live/`.

## Key Architecture Decisions

- **Single source of truth chain**: `accounts/accounts.yaml` (keyed by account slug like `mamstg`, `mamprd`) holds all stack metadata (environment, region, project, account_id, role_name). `input.yaml` holds only `tags:` (common tags) and `resources:` (resource declarations). Account key flows from GitHub Actions `workflow_dispatch` dropdown → `TF_ACCOUNT_KEY` env var → `terragrunt.hcl` + `generate_configs.py --account`.
- **Two-level tag system**: `tags:` at the top of `input.yaml` are common tags applied to every resource. Each resource can define its own `tags:` block under `config:` to add or override specific keys. The HCL output variable is still named `extra_tags` (what Terraform modules expect).
- **Monitoring toggles use `on`/`off`**: `prometheus_monitoring` and `argus_monitoring` in EC2 config use `on`/`off` (not `true`/`false`). PyYAML parses them as booleans — no generator changes needed.
- **No static env/region/project in input.yaml**: These are always derived from `accounts/accounts.yaml` via the account key. Never add them back to `input.yaml`.
- **Flat live/ layout**: `live/<env>/<type>-<name>/terragrunt.hcl` — no nested region or project folders. The `env` directory name comes from `accounts.yaml[key].environment`.
- **name_prefix vs environment**: `name_prefix` (e.g. `stg`, `prd`, `dev`) drives all resource names. `environment` (e.g. `stg`, `prod`, `dev`) is used only for tags and state paths. They can differ.
- **Single file for all environments**: `input.yaml` is the only file users edit. `enabled:` per resource is a dict `{dev: true, stg: false, prod: true}` — the generator reads the resolved env and picks the right value. `env_config:` holds per-env config overrides (memory, instance_type, retention, etc.) merged on top of `config:` at generation time. No separate env files needed.
- **Smart dependency wiring**: `generate_configs.py` only adds Terragrunt `dependency` blocks when the target resource is also `enabled: true`. Disabled dependencies are silently skipped to prevent "no outputs" errors.
- **Deployment order**: `generate_configs.py` sorts by `TYPE_ORDER` (ecr → sns → sqs → lambda → s3 → ec2 → cloudfront). Destroy runs in reverse.

## Commands

### Generate Terragrunt configs locally
```bash
python3 scripts/generate_configs.py input.yaml . --account mamstg
```
This writes `live/<env>/<type>-<name>/terragrunt.hcl` for each enabled resource and a `generated_modules.txt` manifest.

### Generate for a single resource (used by destroy workflow)
```bash
python3 scripts/generate_configs.py input.yaml . --account mamstg --target ec2-api-server
```

### Look up account metadata
```bash
python3 scripts/get_account_info.py mamstg account_id
python3 scripts/get_account_info.py mamstg region
```

### Run Terragrunt locally (requires AWS creds + TF_ACCOUNT_KEY)
```bash
export TF_ACCOUNT_KEY=mamstg
export MGMT_ACCOUNT_ID=111111111111
cd live/stg/s3-app-assets
terragrunt plan
terragrunt apply
```

### Python dependencies
```bash
pip install -r scripts/requirements.txt   # pyyaml, boto3
```

### Override a single resource config for one environment only
Edit `envs/<env>.yaml` — only list the keys that differ:
```yaml
# envs/prod.yaml
resources:
  - name: api-server
    type: ec2
    config:
      instance_type: t4g.xlarge   # prod gets a bigger box
```

## CI/CD Workflows

All three workflows use the same auth pattern: OIDC into management account → `sts:AssumeRole` into target account.

- **deploy.yml** — `workflow_dispatch` only (no push trigger). Flow: resolve account → plan + cost estimate → approval gate → apply or destroy. Account dropdown drives everything.
- **destroy.yml** — Dedicated destroy with double confirmation (must type account key twice). Supports single-resource destroy via `resource_target` input.
- **drift-detection.yml** — Nightly cron (`0 2 * * *`) across dev/stg/prod. Uses `plan -detailed-exitcode`. Opens/updates GitHub Issues on drift.

GitHub Secrets needed: `MGMT_ACCOUNT_ID`, `MGMT_ROLE_NAME`, `INFRACOST_API_KEY` (optional).
GitHub Environments needed: `dev-approval`, `stg-approval`, `prod-approval` (with required reviewers).

## Resource Naming Convention

All resources: `<name_prefix>-<region>-<project>-<type>-<name>`

Example: `stg-ap-south-1-mam-lambda-image-processor`

## Environment Configuration (single file)

Everything lives in `input.yaml`. For each resource:

```yaml
- name: api-server
  type: ec2
  enabled:           # which environments deploy this resource
    dev:  false
    stg:  true
    prod: true
  config:            # base config — shared across all envs
    instance_type: t4g.small
    ...
  env_config:        # per-env overrides — merged on top of config at generation time
    prod:
      instance_type: t4g.xlarge
      argus_monitoring: on
```

| What changes | Where in input.yaml |
|---|---|
| Turn a resource on/off per env | `enabled.dev / enabled.stg / enabled.prod` |
| Env-specific sizing/flags | `env_config.<env>:` sub-keys |
| Base config (shared) | `config:` |
| Tags for all resources | top-level `tags:` |
| Tags for one resource | `config.tags:` |

## Adding a New Resource Type

1. Create `modules/<type>/` with `main.tf`, `variables.tf`, `outputs.tf`
2. Add a `gen_<type>()` function in `scripts/generate_configs.py`
3. Register it in the `GENERATORS` dict and add to `TYPE_ORDER`
4. Add a resource entry in `input.yaml` under `resources:`

## Adding a New Account

1. Add entry to `accounts/accounts.yaml` with all required fields (environment, name_prefix, project_name, account_id, role_name, region, owner, cost_center)
2. Add the key to the `options:` list in both `deploy.yml` and `destroy.yml` workflow_dispatch inputs
3. Run `bootstrap/target_role` in the new account
4. Create the corresponding GitHub Environment (e.g. `prod-approval`)

## Common Pitfalls

- The root `terragrunt.hcl` reads `TF_ACCOUNT_KEY` from env with `get_env()`. For local runs, either export it or add a temporary `account:` key to `input.yaml` (the `try()` fallback reads it).
- `generate_configs.py` requires `--account` in CI. It falls back to `data["account"]` in `input.yaml` for local use.
- Terraform modules use `mock_outputs_allowed_terraform_commands = ["validate", "plan", "destroy"]` — mocks are never used during apply.
- The apply job intentionally re-plans instead of using saved `.tfplan` files. Terragrunt re-resolves `dependency` outputs at apply time, which can differ from plan time (mock vs real values), causing Terraform "Can't change variable" errors. Plan files are kept for cost estimation and audit.
