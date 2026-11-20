# terraform-azure-gha

[![terraform](https://github.com/Disassemblern/terraform-azure-gha/actions/workflows/terraform.yml/badge.svg)](https://github.com/Disassemblern/terraform-azure-gha/actions/workflows/terraform.yml)

Terraform deploys a static website to Azure Storage. GitHub Actions runs it, using OIDC to authenticate so the repo stores no cloud credentials.

## How it works

```mermaid
flowchart LR
  PR[Pull request] --> Plan[fmt / validate / plan]
  Plan --> Comment[Plan posted as PR comment]
  PR -->|merge| Main[push to main]
  Main --> Gate{production environment<br/>manual approval}
  Gate --> Apply[terraform apply]
  Apply --> Azure[(Azure: RG + Storage static website)]
  Plan -. OIDC token .-> Entra[Entra ID federated credential]
  Apply -. OIDC token .-> Entra
```

- **No secrets in CI:** GitHub issues a short-lived OIDC token, and Entra ID exchanges it for an Azure access token. The federated credentials trust only this repo's `pull_request` events and its `production` environment. They are pinned to the repo's numeric owner and repo IDs, so a re-created repo with the same name gets no access.
- **Remote state:** an Azure Storage backend with blob versioning and lease-based locking.
- **Gated applies:** every push to `main` waits for approval in the `production` environment.
- **Teardown:** run the workflow manually with `destroy` checked.
- **Cost:** about $0. It uses one LRS storage account for the site and one for state.

## Layout

```
bootstrap/bootstrap.sh       one-time setup: state storage, OIDC identity, GitHub secrets
infra/                       Terraform: resource group, storage account, static website, index.html
.github/workflows/terraform.yml
```

## Reproduce

Requires the Azure CLI, the GitHub CLI and Terraform 1.17.

```sh
az login
gh auth login
./bootstrap/bootstrap.sh     # prints the local init command at the end
```

Then open a PR. The plan is posted as a comment on it. Merge the PR and approve the deployment to apply. The website URL appears in the job summary.

Local run:

```sh
terraform -chdir=infra init -backend-config=storage_account_name=<printed by bootstrap>
terraform -chdir=infra plan
```
