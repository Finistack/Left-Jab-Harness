#!/usr/bin/env bash
# ado_auth.sh — Multi-method ADO authentication abstraction
# Supports PAT, Entra ID Service Principal, and Workload Identity Federation.
# Source this file to get get_ado_auth_header() and get_ado_auth_header_cached().
#
# Required environment (depends on ADO_AUTH_METHOD):
#   pat:       ADO_PAT
#   entra-sp:  AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET
#   entra-wi:  AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_FEDERATED_TOKEN_FILE

# Azure DevOps well-known resource ID
_ADO_RESOURCE_ID="499b84ac-1321-427f-aa17-267ca6975798"

# Token cache for Entra ID auth (avoid re-fetching on every API call)
_ADO_TOKEN_CACHE=""
_ADO_TOKEN_EXPIRY=0

# Returns the Authorization header value for ADO API calls.
# Usage: auth_header=$(get_ado_auth_header)
#        curl -H "Authorization: $auth_header" ...
get_ado_auth_header() {
  case "${ADO_AUTH_METHOD:-pat}" in
    pat)
      : "${ADO_PAT:?ADO_PAT required when ADO_AUTH_METHOD=pat}"
      echo "Basic $(echo -n ":${ADO_PAT}" | base64 | tr -d '\n')"
      ;;
    entra-sp)
      : "${AZURE_TENANT_ID:?AZURE_TENANT_ID required for entra-sp}"
      : "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required for entra-sp}"
      : "${AZURE_CLIENT_SECRET:?AZURE_CLIENT_SECRET required for entra-sp}"
      local token
      token=$(curl -s --max-time 15 -X POST \
        "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
        --data-urlencode "client_id=${AZURE_CLIENT_ID}" \
        --data-urlencode "scope=${_ADO_RESOURCE_ID}/.default" \
        --data-urlencode "grant_type=client_credentials" \
        --data-urlencode "client_secret@-" <<< "${AZURE_CLIENT_SECRET}" | jq -r '.access_token // empty')
      if [ -z "$token" ]; then
        echo "ERROR: Failed to obtain Entra ID token for service principal" >&2
        return 1
      fi
      echo "Bearer $token"
      ;;
    entra-wi)
      : "${AZURE_TENANT_ID:?AZURE_TENANT_ID required for entra-wi}"
      : "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID required for entra-wi}"
      : "${AZURE_FEDERATED_TOKEN_FILE:?AZURE_FEDERATED_TOKEN_FILE required for entra-wi}"
      local federated_token
      federated_token=$(cat "$AZURE_FEDERATED_TOKEN_FILE" 2>/dev/null) || {
        echo "ERROR: Cannot read federated token file: $AZURE_FEDERATED_TOKEN_FILE" >&2
        return 1
      }
      local token
      token=$(curl -s --max-time 15 -X POST \
        "https://login.microsoftonline.com/${AZURE_TENANT_ID}/oauth2/v2.0/token" \
        -d "client_id=${AZURE_CLIENT_ID}" \
        -d "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
        -d "client_assertion=${federated_token}" \
        -d "scope=${_ADO_RESOURCE_ID}/.default" \
        -d "grant_type=client_credentials" | jq -r '.access_token // empty')
      if [ -z "$token" ]; then
        echo "ERROR: Failed to obtain Entra ID token via Workload Identity" >&2
        return 1
      fi
      echo "Bearer $token"
      ;;
    *)
      echo "ERROR: Unknown ADO_AUTH_METHOD: ${ADO_AUTH_METHOD}" >&2
      return 1
      ;;
  esac
}

# Cached version — avoids re-fetching Entra tokens on every API call.
# PAT auth is stateless so caching is a no-op (just returns the header).
get_ado_auth_header_cached() {
  # PAT auth doesn't need caching
  if [ "${ADO_AUTH_METHOD:-pat}" = "pat" ]; then
    get_ado_auth_header
    return
  fi

  local now
  now=$(date +%s)
  if [ "$now" -lt "$_ADO_TOKEN_EXPIRY" ] && [ -n "$_ADO_TOKEN_CACHE" ]; then
    echo "$_ADO_TOKEN_CACHE"
    return
  fi

  _ADO_TOKEN_CACHE=$(get_ado_auth_header) || return 1
  _ADO_TOKEN_EXPIRY=$((now + 3000))  # cache for ~50 min (tokens last 60-90 min)
  echo "$_ADO_TOKEN_CACHE"
}
