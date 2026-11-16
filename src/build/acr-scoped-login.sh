#!/usr/bin/env bash

_acr_scoped_cleanup() {
  local status="$1"
  trap - EXIT
  if [[ -n "${ACR_SCOPED_AUTH_ROOT:-}" ]]; then
    rm -rf -- "$ACR_SCOPED_AUTH_ROOT" || true
  fi
  exit "$status"
}

acr_scoped_login() {
  set +x

  if [[ -z "${servicePrincipalId:-}" || -z "${tenantId:-}" || -z "${idToken:-}" ]]; then
    echo 'Missing AzureCLI workload identity values' >&2
    return 2
  fi

  local task_subscription
  task_subscription=$(az account show --query id --output tsv) || return
  if [[ -z "$task_subscription" ]]; then
    echo 'AzureCLI task has no selected subscription' >&2
    return 2
  fi

  umask 077
  ACR_SCOPED_AUTH_ROOT=$(mktemp -d /tmp/finistack-acr-auth.XXXXXXXX) || return
  trap '_acr_scoped_cleanup "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  AZURE_CONFIG_DIR="$ACR_SCOPED_AUTH_ROOT/azure"
  DOCKER_CONFIG="$ACR_SCOPED_AUTH_ROOT/docker"
  mkdir -m 700 "$AZURE_CONFIG_DIR" "$DOCKER_CONFIG" || return
  export AZURE_CONFIG_DIR DOCKER_CONFIG

  az login --service-principal \
    --username "$servicePrincipalId" \
    --tenant "$tenantId" \
    --federated-token "$idToken" \
    --scope https://containerregistry.azure.net/.default \
    --output none || return
  unset idToken
  az account set --subscription "$task_subscription" || return
  az acr login --name finistackproduction --output none || return
}
