#!/usr/bin/env bash
# pr_workitems.sh — PR Work Item Management
# Provides functions to ensure PRs have linked work items, search for related
# items, and create new ones when needed.
#
# Required: ado_api_call, ADO_BASE, ADO_ORG, ADO_PROJECT, log()

# Ensure a PR has at least one linked work item.
# If none, search by title keywords → attach if found → else create Task.
# Usage: ensure_pr_work_item <pr_id> <repo_id> <pr_details_json>
ensure_pr_work_item() {
  local pr_id="$1"
  local repo_id="$2"
  local pr_details="$3"

  log "🔗 Checking PR work item linkage..."

  if [ -z "$pr_details" ] || ! echo "$pr_details" | jq -e '.pullRequestId' >/dev/null 2>&1; then
    log "⚠️  Could not fetch PR details — skipping work item check"
    return 0
  fi

  # Use the dedicated PR work items endpoint (workItemRefs not in standard PR response)
  local wi_url="${ADO_BASE}/git/repositories/${repo_id}/pullRequests/${pr_id}/workitems?api-version=7.1"
  local wi_response
  wi_response=$(ado_api_call "$wi_url" 2>/dev/null) || wi_response=""
  local work_item_count
  work_item_count=$(echo "$wi_response" | jq '[.value // [] | .[]] | length' 2>/dev/null || echo "0")

  if [ "$work_item_count" != "0" ]; then
    log "🔗 PR #${pr_id} already has $work_item_count linked work item(s)"
    return 0
  fi

  log "🔗 No work items linked to PR #${pr_id}, searching..."
  local pr_title
  pr_title=$(echo "$pr_details" | jq -r '.title // "PR Bot Task"' 2>/dev/null) || pr_title="PR Bot Task"

  # Extract project GUID for linking
  local project_id
  project_id=$(echo "$pr_details" | jq -r '.repository.project.id // empty' 2>/dev/null)
  [ -z "$project_id" ] && project_id="$ADO_PROJECT"

  # Try to find an existing work item by searching title keywords
  local found_wi_id=""
  found_wi_id=$(search_related_work_items "$pr_title")

  if [ -n "$found_wi_id" ]; then
    log "🔗 Found related work item #${found_wi_id}, linking to PR #${pr_id}..."
    _link_work_item_to_pr "$found_wi_id" "$pr_id" "$repo_id" "$project_id"
    _activate_work_item "$found_wi_id" "$pr_details"
    return 0
  fi

  # No matching WI found — create one
  log "🔗 No matching work item found, creating new Task..."
  (
    set +e
    local pr_creator
    pr_creator=$(echo "$pr_details" | jq -r '.createdBy.uniqueName // "dstack"' 2>/dev/null) || pr_creator="dstack"

    local wi_body
    wi_body=$(jq -n --arg title "$pr_title" '[
      {"op":"add","path":"/fields/System.Title","value":$title}
    ]')

    if [ -z "$wi_body" ]; then
      log "⚠️  Failed to construct work item JSON body"
      return 0
    fi

    local wi_response
    wi_response=$(ado_api_call "${ADO_BASE}/wit/workitems/\$Task?api-version=7.1" "POST" "$wi_body" "application/json-patch+json")
    local wi_id
    wi_id=$(echo "$wi_response" | jq -r '.id // empty' 2>/dev/null)

    if [ -n "$wi_id" ]; then
      log "🔗 Created work item #${wi_id}"
      _link_work_item_to_pr "$wi_id" "$pr_id" "$repo_id" "$project_id"
      # Set state + assignee via separate PATCH (avoids create-time state transition issues)
      _activate_work_item "$wi_id" "$pr_details"

      # Try to find and link to a parent epic
      find_parent_epic "$wi_id" "$pr_title"
    else
      log "⚠️  Failed to create work item for PR #${pr_id}"
    fi
  ) || log "⚠️  Work item creation failed (non-fatal, continuing)"
}

# Search for related work items by title keywords.
# Returns the ID of the first matching active work item, or empty string.
# Tries exact title match first, then falls back to keyword search.
# Usage: search_related_work_items <search_text>
search_related_work_items() {
  local search_text="$1"

  # 1. Try exact title match first (avoids false positives from keyword search)
  # Sanitize single quotes to prevent WIQL injection (escape ' → '')
  local safe_title="${search_text//\'/\'\'}"
  local exact_wiql
  exact_wiql=$(jq -n --arg title "$safe_title" '{
    query: ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.State] <> '\''Closed'\'' AND [System.State] <> '\''Done'\'' AND [System.State] <> '\''Removed'\'' AND [System.Title] = '\''" + $title + "'\'' ORDER BY [System.ChangedDate] DESC")
  }')
  local exact_response
  exact_response=$(ado_api_call "${ADO_BASE}/wit/wiql?api-version=7.1&\$top=1" "POST" "$exact_wiql" 2>/dev/null) || exact_response=""
  local exact_wi_id
  exact_wi_id=$(echo "$exact_response" | jq -r '.workItems[0].id // empty' 2>/dev/null)

  if [ -n "$exact_wi_id" ] && [ "$exact_wi_id" != "null" ]; then
    echo "$exact_wi_id"
    return 0
  fi

  # 2. Fall back to keyword search
  local keywords
  keywords=$(echo "$search_text" | sed 's|^[a-z]*/||; s|^[a-z]*:||; s|[^a-zA-Z0-9 ]| |g' | tr -s ' ' | head -c 100)

  [ -z "$keywords" ] && return 0

  local wiql
  wiql=$(jq -n --arg kw "$keywords" '{
    query: ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.State] <> '\''Closed'\'' AND [System.State] <> '\''Done'\'' AND [System.State] <> '\''Removed'\'' AND [System.Title] CONTAINS WORDS '\''" + $kw + "'\'' ORDER BY [System.ChangedDate] DESC")
  }')

  local response
  response=$(ado_api_call "${ADO_BASE}/wit/wiql?api-version=7.1&\$top=1" "POST" "$wiql" 2>/dev/null) || return 0

  local wi_id
  wi_id=$(echo "$response" | jq -r '.workItems[0].id // empty' 2>/dev/null)

  if [ -n "$wi_id" ] && [ "$wi_id" != "null" ]; then
    echo "$wi_id"
  fi
}

# Find a parent Epic and link the work item as a child.
# Usage: find_parent_epic <work_item_id> <search_text>
find_parent_epic() {
  local wi_id="$1"
  local search_text="$2"

  # Search for Epics matching keywords
  local keywords
  keywords=$(echo "$search_text" | sed 's|^[a-z]*/||; s|^[a-z]*:||; s|[^a-zA-Z0-9 ]| |g' | tr -s ' ' | head -c 60)

  [ -z "$keywords" ] && return 0

  local wiql
  wiql=$(jq -n --arg kw "$keywords" '{
    query: ("SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.WorkItemType] = '\''Epic'\'' AND [System.State] <> '\''Closed'\'' AND [System.State] <> '\''Done'\'' AND [System.Title] CONTAINS WORDS '\''" + $kw + "'\'' ORDER BY [System.ChangedDate] DESC")
  }')

  local response
  response=$(ado_api_call "${ADO_BASE}/wit/wiql?api-version=7.1&\$top=1" "POST" "$wiql" 2>/dev/null) || return 0

  local epic_id
  epic_id=$(echo "$response" | jq -r '.workItems[0].id // empty' 2>/dev/null)

  if [ -n "$epic_id" ] && [ "$epic_id" != "null" ]; then
    log "🔗 Found parent Epic #${epic_id}, linking as child..."
    local link_body
    link_body=$(jq -n --arg url "https://dev.azure.com/${ADO_ORG}/${ADO_PROJECT}/_apis/wit/workItems/${epic_id}" '[
      {"op":"add","path":"/relations/-","value":{"rel":"System.LinkTypes.Hierarchy-Reverse","url":$url,"attributes":{"comment":"Linked by Left Jab Bot"}}}
    ]')
    ado_api_call "${ADO_BASE}/wit/workitems/${wi_id}?api-version=7.1" "PATCH" "$link_body" "application/json-patch+json" >/dev/null 2>&1 || \
      log "⚠️  Failed to link work item #${wi_id} to Epic #${epic_id}"
  fi
}

# Internal: Activate a work item — transition to the first "InProgress" state
# and assign to the PR creator. Queries the ADO API for valid states rather than
# hardcoding state names (supports Basic, Agile, Scrum, CMMI processes).
#
# State and assignee are set in separate PATCH calls so one failure doesn't
# block the other (e.g., invalid assignee shouldn't prevent state transition).
_activate_work_item() {
  local wi_id="$1"
  local pr_details="$2"

  # --- Resolve assignee ---
  local pr_creator
  pr_creator=$(echo "$pr_details" | jq -r '.createdBy.uniqueName // ""' 2>/dev/null) || pr_creator=""

  # Service identities can't be assigned work items — use a configured fallback owner.
  # ADO creator formats vary: "Build\ServiceAccount", "<Org> Build Service (<org>)",
  # "vstfs:///..." — match all service-identity variants.
  if [ -z "$pr_creator" ] || [[ "$pr_creator" == Build\\* ]] || [[ "$pr_creator" == *"Build Service"* ]] || [[ "$pr_creator" == vstfs://* ]]; then
    pr_creator="${WORKITEM_FALLBACK_OWNER:-}"
  fi

  # --- Resolve target state dynamically ---
  # 1. Get the work item's current state and type
  local wi_response
  wi_response=$(ado_api_call "${ADO_BASE}/wit/workitems/${wi_id}?\$fields=System.State,System.WorkItemType&api-version=7.1" 2>/dev/null) || {
    log "⚠️  Failed to fetch work item #${wi_id} details — skipping activation"
    return 0
  }
  local current_state wi_type
  current_state=$(echo "$wi_response" | jq -r '.fields["System.State"] // ""' 2>/dev/null)
  wi_type=$(echo "$wi_response" | jq -r '.fields["System.WorkItemType"] // "Task"' 2>/dev/null)

  # 2. Query valid states for this work item type
  local states_response
  states_response=$(ado_api_call "${ADO_BASE}/wit/workitemtypes/${wi_type// /%20}/states?api-version=7.1" 2>/dev/null) || {
    log "⚠️  Failed to fetch states for work item type '${wi_type}' — skipping state transition"
    # Still try to set assignee even if state lookup fails
    local assign_body
    assign_body=$(jq -n --arg assignee "$pr_creator" '[
      {"op":"add","path":"/fields/System.AssignedTo","value":$assignee}
    ]')
    ado_api_call "${ADO_BASE}/wit/workitems/${wi_id}?api-version=7.1" "PATCH" "$assign_body" "application/json-patch+json" >/dev/null 2>&1 || \
      log "⚠️  Failed to assign work item #${wi_id} to ${pr_creator}"
    return 0
  }

  # 3. Find the first InProgress state (the "active" state for any process template)
  local target_state
  target_state=$(echo "$states_response" | jq -r '[.value[] | select(.category == "InProgress")][0].name // ""' 2>/dev/null)

  if [ -z "$target_state" ]; then
    log "⚠️  No InProgress state found for work item type '${wi_type}' — skipping state transition"
  fi

  # 4. Check if already in target state or a later state (InProgress or Completed)
  local current_category
  current_category=$(echo "$states_response" | jq -r --arg s "$current_state" '[.value[] | select(.name == $s)][0].category // "Proposed"' 2>/dev/null)

  # --- Apply assignee (separate call) ---
  log "🔗 Assigning work item #${wi_id} to ${pr_creator}..."
  local assign_body
  assign_body=$(jq -n --arg assignee "$pr_creator" '[
    {"op":"add","path":"/fields/System.AssignedTo","value":$assignee}
  ]')
  ado_api_call "${ADO_BASE}/wit/workitems/${wi_id}?api-version=7.1" "PATCH" "$assign_body" "application/json-patch+json" >/dev/null 2>&1 || \
    log "⚠️  Failed to assign work item #${wi_id} to ${pr_creator}"

  # --- Apply state transition (separate call) ---
  if [ -n "$target_state" ] && [ "$current_category" = "Proposed" ]; then
    log "🔗 Transitioning work item #${wi_id} from '${current_state}' to '${target_state}'..."
    local state_body
    state_body=$(jq -n --arg state "$target_state" '[
      {"op":"add","path":"/fields/System.State","value":$state}
    ]')
    ado_api_call "${ADO_BASE}/wit/workitems/${wi_id}?api-version=7.1" "PATCH" "$state_body" "application/json-patch+json" >/dev/null 2>&1 || \
      log "⚠️  Failed to transition work item #${wi_id} to '${target_state}'"
  elif [ -n "$target_state" ]; then
    log "🔗 Work item #${wi_id} already in '${current_state}' (${current_category}) — skipping state transition"
  fi
}

# Internal: Link a work item to a PR via ArtifactLink
_link_work_item_to_pr() {
  local wi_id="$1"
  local pr_id="$2"
  local repo_id="$3"
  local project_id="$4"

  log "🔗 Linking work item #${wi_id} to PR #${pr_id}..."
  local link_body
  link_body=$(jq -n --arg prUrl "vstfs:///Git/PullRequestId/${project_id}%2f${repo_id}%2f${pr_id}" '[
    {"op":"add","path":"/relations/-","value":{"rel":"ArtifactLink","url":$prUrl,"attributes":{"name":"Pull Request"}}}
  ]')
  ado_api_call "${ADO_BASE}/wit/workitems/${wi_id}?api-version=7.1" "PATCH" "$link_body" "application/json-patch+json" >/dev/null 2>&1 || \
    log "⚠️  Failed to link work item #${wi_id} to PR (may need manual linking)"
}
