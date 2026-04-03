#!/usr/bin/env bash
set -euo pipefail

# scripts/preprovision.sh
# azd preprovision hook — ensures the target resource group exists (with
# optional custom tags) before azd provision runs the Bicep deployment.
#
# Environment variables (set by azd or the calling workflow):
#   AZURE_ENV_NAME          – azd environment name              (required)
#   AZURE_LOCATION          – Azure region                      (required)
#   AZURE_SUBSCRIPTION_ID   – Azure subscription                (optional; uses az default)
#   PREPROVISION_RG_TAGS    – JSON object of extra tags          (optional)
#                             Example: '{"team":"platform","cost-center":"12345"}'

: "${AZURE_ENV_NAME:?AZURE_ENV_NAME is required}"
: "${AZURE_LOCATION:?AZURE_LOCATION is required}"

RG_NAME="rg-${AZURE_ENV_NAME}"

echo "Ensuring resource group '${RG_NAME}' exists in '${AZURE_LOCATION}'..."

# Build base arguments
args=(--name "$RG_NAME" --location "$AZURE_LOCATION")

if [ -n "${AZURE_SUBSCRIPTION_ID:-}" ]; then
  args+=(--subscription "$AZURE_SUBSCRIPTION_ID")
fi

# Collect tags: always include the azd-env-name tag (matches the Bicep
# template convention), then merge any custom tags from the secret.
args+=(--tags "azd-env-name=${AZURE_ENV_NAME}")

if [ -n "${PREPROVISION_RG_TAGS:-}" ]; then
  echo "Applying custom tags from PREPROVISION_RG_TAGS..."
  if ! echo "$PREPROVISION_RG_TAGS" | jq empty 2>/dev/null; then
    echo "::error::PREPROVISION_RG_TAGS is not valid JSON"
    exit 1
  fi
  while IFS= read -r tag; do
    [ -n "$tag" ] && args+=("$tag")
  done < <(echo "$PREPROVISION_RG_TAGS" | jq -r 'to_entries[] | "\(.key)=\(.value)"')
fi

az group create "${args[@]}"
echo "Resource group '${RG_NAME}' is ready."
