#!/usr/bin/env python3
"""
scripts/get_account_info.py <account_key> <field>

Reads accounts/accounts.yaml and prints the value of <field> for <account_key>.
Used by CI workflows to resolve region, account_id, role_name, environment etc.

Examples:
  python3 scripts/get_account_info.py mamstg account_id
  python3 scripts/get_account_info.py mamprd environment
  python3 scripts/get_account_info.py tvplusdev region
"""
import sys, yaml
from pathlib import Path

if len(sys.argv) < 3:
    print("Usage: get_account_info.py <account_key> <field>", file=sys.stderr)
    sys.exit(1)

account_key = sys.argv[1]
field       = sys.argv[2]

accounts_file = Path("accounts/accounts.yaml")
if not accounts_file.exists():
    print(f"ERROR: accounts/accounts.yaml not found", file=sys.stderr)
    sys.exit(1)

data = yaml.safe_load(accounts_file.read_text())

if account_key not in data:
    print(f"ERROR: account key '{account_key}' not found in accounts.yaml", file=sys.stderr)
    print(f"Available keys: {', '.join(data.keys())}", file=sys.stderr)
    sys.exit(1)

if field not in data[account_key]:
    print(f"ERROR: field '{field}' not found for account '{account_key}'", file=sys.stderr)
    print(f"Available fields: {', '.join(data[account_key].keys())}", file=sys.stderr)
    sys.exit(1)

val = data[account_key][field]
if val is None or val == "":
    print(f"ERROR: field '{field}' is empty for account '{account_key}'", file=sys.stderr)
    sys.exit(1)

print(val)
