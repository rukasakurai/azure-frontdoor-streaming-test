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
#   PREPROVISION_RG_TAGS    – Space-separated key=value tags     (optional)
#                             Example: 'team=platform cost-center=12345'
#                             Single tag:  'team=platform'

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
# template convention), then append any custom tags from the env var.
args+=(--tags "azd-env-name=${AZURE_ENV_NAME}")

if [ -n "${PREPROVISION_RG_TAGS:-}" ]; then
  echo "Applying custom tags from PREPROVISION_RG_TAGS..."
  # shellcheck disable=SC2086
  # Word-splitting is intentional: each key=value pair becomes a separate arg.
  # Disable globbing so wildcards in values are not expanded.
  set -f
  for tag in $PREPROVISION_RG_TAGS; do
    args+=("$tag")
  done
  set +f
fi

az group create "${args[@]}"
echo "Resource group '${RG_NAME}' is ready."
