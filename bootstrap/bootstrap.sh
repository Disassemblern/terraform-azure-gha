#!/usr/bin/env bash
# One-time setup: Terraform state storage, an OIDC identity for GitHub Actions,
# and the repo secrets/variables/environment the workflow needs.
# Requires: az and gh, both logged in. Safe to re-run.
set -euo pipefail
export MSYS_NO_PATHCONV=1 # stop Git Bash on Windows from rewriting /subscriptions/... args

REPO="${REPO:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
LOCATION="${LOCATION:-swedencentral}"
STATE_RG=rg-tfstate
APP_NAME="gha-${REPO#*/}"

SUB_ID=$(az account show --query id -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
# Storage account names are global; derive a stable one from the subscription.
STATE_SA="tfstate$(printf %s "$SUB_ID" | sha1sum | cut -c1-8)"

echo "==> Registering Microsoft.Storage provider"
az provider register --namespace Microsoft.Storage --wait

echo "==> State storage: $STATE_SA"
az group create -n "$STATE_RG" -l "$LOCATION" -o none
az storage account create -n "$STATE_SA" -g "$STATE_RG" -l "$LOCATION" \
  --sku Standard_LRS --min-tls-version TLS1_2 --allow-blob-public-access false -o none
az storage account blob-service-properties update -n "$STATE_SA" -g "$STATE_RG" \
  --enable-versioning true -o none
az storage container create -n tfstate --account-name "$STATE_SA" --auth-mode key -o none

echo "==> App registration: $APP_NAME"
APP_ID=$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)
[ -n "$APP_ID" ] || APP_ID=$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)
SP_ID=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null) ||
  SP_ID=$(az ad sp create --id "$APP_ID" --query id -o tsv)

# Subject prefix as GitHub puts it in the token. It pins owner and repo IDs
# (repo:owner@123/name@456), so a re-created repo with the same name is not trusted.
SUBJECT=$(gh api "repos/$REPO/actions/oidc/customization/sub" --jq .sub_claim_prefix)

add_federated_credential() { # name subject
  if az ad app federated-credential list --id "$APP_ID" --query '[].subject' -o tsv | grep -qxF "$2"; then
    return
  fi
  # Replace a same-named credential with an outdated subject; absent is fine.
  az ad app federated-credential delete --id "$APP_ID" --federated-credential-id "$1" 2>/dev/null || true
  # JSON via a relative file: az.cmd mangles inline JSON quotes on Windows.
  printf '{"name":"%s","issuer":"https://token.actions.githubusercontent.com","subject":"%s","audiences":["api://AzureADTokenExchange"]}' \
    "$1" "$2" >fic.json
  az ad app federated-credential create --id "$APP_ID" --parameters @fic.json -o none
  rm fic.json
}
add_federated_credential gha-pull-request "$SUBJECT:pull_request"
add_federated_credential gha-production "$SUBJECT:environment:production"
# Scheduled drift check runs on main. Only merged code runs there (main is protected).
# ponytail: shares the Contributor identity; a separate read-only identity if the repo gains collaborators.
add_federated_credential gha-main "$SUBJECT:ref:refs/heads/main"

echo "==> Contributor on subscription"
SCOPE="/subscriptions/$SUB_ID"
if [ -z "$(az role assignment list --assignee "$SP_ID" --role Contributor --scope "$SCOPE" --query '[].id' -o tsv)" ]; then
  az role assignment create --assignee-object-id "$SP_ID" --assignee-principal-type ServicePrincipal \
    --role Contributor --scope "$SCOPE" -o none
fi

echo "==> GitHub secrets, variable, environment on $REPO"
gh secret set AZURE_CLIENT_ID -R "$REPO" -b "$APP_ID"
gh secret set AZURE_TENANT_ID -R "$REPO" -b "$TENANT_ID"
gh secret set AZURE_SUBSCRIPTION_ID -R "$REPO" -b "$SUB_ID"
gh variable set TFSTATE_STORAGE_ACCOUNT -R "$REPO" -b "$STATE_SA"
gh api -X PUT "repos/$REPO/environments/production" --silent \
  -F "reviewers[][type]=User" -F "reviewers[][id]=$(gh api user -q .id)"

echo "Done. Local init: terraform -chdir=infra init -backend-config=storage_account_name=$STATE_SA"
