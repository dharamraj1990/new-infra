# Approval Email Setup

GitHub sends approval emails natively — no SMTP or third-party config needed.

## One-time setup per environment

Go to **GitHub repo → Settings → Environments**

Create these environments and add reviewers to each `-approval` one:

| Environment | Required Reviewers | Notes |
|---|---|---|
| `dev-plan` | — | No gate needed |
| `dev-approval` | Add team members | GitHub emails them when pending |
| `dev-apply` | — | No gate needed |
| `stg-approval` | Add team members | |
| `prod-approval` | Senior engineers only | Enable "Prevent self-review" |

## How it works

1. Someone pushes to `main` or manually triggers the workflow
2. The `plan` job runs → cost estimate appears in the run summary
3. The `approval` job starts and enters **Waiting** state
4. **GitHub automatically emails every Required Reviewer** with:
   - A link directly to the Actions run
   - Who triggered it and what environment
5. Reviewer opens the link → clicks **Review deployments** → selects the environment → **Approve** or **Reject**
6. `apply` or `destroy` job unblocks and runs

## Recommended settings per environment

For `prod-approval`:
- Required reviewers: 2 minimum
- Prevent self-review: ✅ enabled
- Wait timer: 5 minutes (gives time to catch mistakes)

For `stg-approval`:
- Required reviewers: 1
- Prevent self-review: ✅ enabled

For `dev-approval`:
- Required reviewers: 1
- Prevent self-review: optional
