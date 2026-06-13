#!/usr/bin/env bash
# ado_api.sh — Shared Azure DevOps API utilities for all Finistack bots.
# Source this file to get ADO API call helpers with retry, auth, and error handling.
#
# Required environment:
#   ADO_AUTH_METHOD — "pat" (default), "entra-sp", or "entra-wi"
#   ADO_PAT        — Azure DevOps Personal Access Token (when ADO_AUTH_METHOD=pat)
#   ADO_ORG        — Azure DevOps organization name
#   ADO_PROJECT    — Azure DevOps project name
#
# Usage:
#   source "$(dirname "$0")/../shared/ado_api.sh"
#   response=$(ado_get "$url")
#   response=$(ado_post "$url" "$body")
#   response=$(ado_patch "$url" "$body")
#   response=$(ado_api_call "$url" "PUT" "$body" "application/json")

# Portable base64 encoding that works on both GNU (Linux) and BSD (macOS).
# GNU base64 wraps at 76 chars by default, which corrupts HTTP headers.
b64_encode() { base64 | tr -d '\n'; }

# Source auth abstraction (multi-method: PAT, Entra SP, Entra WI)
_ADO_API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_ADO_API_DIR/ado_auth.sh" ]; then
  # shellcheck source=ado_auth.sh
  source "$_ADO_API_DIR/ado_auth.sh"
fi

# ADO API call with exponential backoff retry and full error logging.
# Usage: ado_api_call <url> [method] [body] [content_type]
# Outputs response body on success, returns non-zero on failure.
ado_api_call() {
  local url="$1"
  local method="${2:-GET}"
  local body="${3:-}"
  local content_type="${4:-application/json}"
  local max_retries=3
  local retry_delay=2
  local attempt=0
  local tmpfile
  tmpfile=$(mktemp)

  while [ "$attempt" -le "$max_retries" ]; do
    local auth_header
    auth_header=$(get_ado_auth_header_cached 2>/dev/null) || auth_header="Basic $(echo -n ":${ADO_PAT:-}" | b64_encode)"
    local http_code
    if [ -n "$body" ]; then
      http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' \
        -X "$method" \
        -H "Authorization: $auth_header" \
        -H "Content-Type: ${content_type}" \
        -d "$body" \
        --max-time 30 \
        "$url" 2>/dev/null) || http_code="000"
    else
      http_code=$(curl -s -o "$tmpfile" -w '%{http_code}' \
        -H "Authorization: $auth_header" \
        --max-time 30 \
        "$url" 2>/dev/null) || http_code="000"
    fi

    # Auth failures — not transient, bail immediately
    if [[ "$http_code" =~ ^(302|401|403)$ ]] || grep -q '<html>' "$tmpfile" 2>/dev/null; then
      echo "❌ ADO API auth failure (HTTP $http_code) — check ADO_PAT validity" >&2
      echo "❌ URL: $url" >&2
      cat "$tmpfile" >&2
      rm -f "$tmpfile"
      return 1
    fi

    # Success
    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      cat "$tmpfile"
      rm -f "$tmpfile"
      return 0
    fi

    # Transient — retry with backoff
    if [ "$attempt" -lt "$max_retries" ]; then
      echo "⚠️  ADO API HTTP $http_code (attempt $((attempt+1))/$max_retries), retrying in ${retry_delay}s..." >&2
      echo "⚠️  URL: $url" >&2
      sleep "$retry_delay"
      retry_delay=$((retry_delay * 2))
    else
      echo "❌ ADO API failed after $((max_retries+1)) attempts (HTTP $http_code)" >&2
      echo "❌ URL: $url" >&2
      cat "$tmpfile" >&2
      rm -f "$tmpfile"
      return 1
    fi
    attempt=$((attempt + 1))
  done
  rm -f "$tmpfile"
  return 1
}

# Convenience wrappers
ado_get() {
  ado_api_call "$1"
}

ado_post() {
  ado_api_call "$1" "POST" "$2" "${3:-application/json}"
}

ado_patch() {
  ado_api_call "$1" "PATCH" "$2" "${3:-application/json}"
}

ado_put() {
  ado_api_call "$1" "PUT" "$2" "${3:-application/json}"
}

# Build the ADO API base URL
ado_base_url() {
  echo "https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis"
}
