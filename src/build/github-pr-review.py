#!/usr/bin/env python3
"""Post Claude Code review results as PR comments on GitHub.

GitHub analogue of the Azure DevOps poster (`post-pr-review.py`). The canonical
object is the GitHub **review thread**: resolution state and the thread node-id are
GraphQL-only, while bodies/paths/authors are available over REST. This poster reads
threads via one GraphQL query (authoritative) plus the REST issue-comments endpoint
(PR-level notes), correlates them by `comments.databaseId == REST comment id`, and
uses REST for all writes.

Supports:
- File-level deduplication: skips files that already have Claude Review threads
- Comment-level deduplication: skips identical comments (deterministic checks)
- check_id-based deduplication: updates existing threads in place (dormant — the
  harness prompt emits no check_id — but ported for parity/extensibility)
- Auto-resolve: resolves unresolved Claude Review threads that have a human reply
- Clean review: approves the PR (as the bot identity) and posts a check note
- 422 fallback: a finding whose line is not in the diff is posted as a PR-level note

Standard library only (urllib); no third-party dependencies.
"""
import json
import os
import re
import time
import urllib.error
import urllib.request


REVIEW_FILE = os.environ.get("REVIEW_FILE", "/tmp/review-results.json")
API_BASE = os.environ.get("GH_API_URL", "https://api.github.com").rstrip("/")
GRAPHQL_URL = API_BASE + "/graphql"
USER_AGENT = os.environ.get("GH_USER_AGENT", "left-jab-harness-claude-review")
API_VERSION = "2022-11-28"

REQUEST_DELAY = float(os.environ.get("GH_REQUEST_DELAY", "0.5"))
MAX_INLINE_COMMENTS = int(os.environ.get("GH_MAX_INLINE_COMMENTS", "30"))
MAX_RETRIES = 3
RETRY_BACKOFF = 2
MAX_RETRY_SLEEP = 60

SEVERITY_LABELS = {"critical": "[HIGH]", "warning": "[MED]", "info": "[LOW]"}


# --------------------------------------------------------------------------- #
# Pure helpers (no network — unit-tested by github-pr-review-test.sh)
# --------------------------------------------------------------------------- #

def severity_label(severity):
    """Map a severity to its display label, defaulting to [LOW]."""
    return SEVERITY_LABELS.get(severity, "[LOW]")


def normalize_path(path):
    """Normalize a file path for the GitHub API: strip the leading slash.

    This is the inverse of the ADO poster, which *prepends* a slash. GitHub
    `path` fields and inline-comment payloads use repo-relative paths with no
    leading slash.
    """
    return (path or "").lstrip("/")


def normalize_comment(content):
    """Normalize comment content for deduplication comparison.

    Strips the severity prefix, the Claude Review header, and the optional
    ``(`path:line`)`` fallback-location marker so the same underlying issue
    matches regardless of whether it was posted inline or as a PR-level note.
    """
    normalized = re.sub(r"^\[(?:HIGH|MED|LOW)\]\s*", "", (content or "").strip())
    normalized = re.sub(r"\*\*\[Claude Review[^\]]*\]\*\*\s*", "", normalized)
    normalized = re.sub(r"\(`[^`]+`\)\s*", "", normalized)
    return normalized.strip()


def build_comment_body(severity, comment, check_id=None, location=None):
    """Assemble a comment body matching the ADO poster's format.

    Optional `check_id` embeds an HTML marker for in-place updates; optional
    `location` (``path`` or ``path:line``) renders a ``(`location`)`` marker for
    PR-level fallback notes (stripped by `normalize_comment` for dedup symmetry).
    """
    label = severity_label(severity)
    header = f"{label} **[Claude Review - {(severity or 'info').upper()}]**"
    body = ""
    if check_id:
        body += f"<!-- check_id:{check_id} -->\n"
    body += header + "\n\n"
    if location:
        body += f"(`{location}`)\n\n"
    body += comment if comment else "No details"
    return body


def extract_check_id(content):
    """Extract a check_id from an HTML marker: <!-- check_id:some-id -->."""
    match = re.search(r"<!--\s*check_id:(.+?)\s*-->", content or "")
    return match.group(1).strip() if match else None


def parse_fallback_location(body):
    """Recover ``(path, line)`` from a fallback note's ``(`path:line`)`` marker.

    Returns ``(path, line)`` with an int line, ``(path, None)`` when only a path
    is present, or ``(None, None)`` when no marker is found.
    """
    match = re.search(r"\(`([^`]+)`\)", body or "")
    if not match:
        return (None, None)
    inside = match.group(1)
    line_match = re.match(r"^(.*):(\d+)$", inside)
    if line_match:
        return (line_match.group(1), int(line_match.group(2)))
    return (inside, None)


def extract_review_from_claude_output(raw):
    """Extract the review JSON array from the Claude CLI output envelope."""
    parsed = json.loads(raw)

    if isinstance(parsed, list):
        return parsed

    if isinstance(parsed, dict) and "result" in parsed:
        result_str = parsed["result"]
        if not isinstance(result_str, str):
            return result_str if isinstance(result_str, list) else []

        stripped = re.sub(r"^```(?:json)?\s*\n?", "", result_str.strip())
        stripped = re.sub(r"\n?```\s*$", "", stripped)

        try:
            inner = json.loads(stripped)
            return inner if isinstance(inner, list) else [inner]
        except (json.JSONDecodeError, ValueError):
            print(f"Failed to parse inner result JSON, length={len(stripped)}")
            return []

    if isinstance(parsed, dict) and "comment" in parsed:
        return [parsed]

    return []


def is_claude_review_thread(thread):
    """True if any comment in the thread is a Claude Review comment."""
    for comment in thread.get("comments", []):
        if "[Claude Review" in comment.get("body", ""):
            return True
    return False


def is_duplicate_comment(file_path, comment, existing_signatures):
    """True if (normalized path, normalized comment) is already present."""
    normalized = normalize_comment(comment)
    return (normalize_path(file_path), normalized) in existing_signatures


def build_signatures(threads, issue_comments):
    """Build the file-level and comment-level dedup sets.

    Returns ``(reviewed_files, signatures)`` where `reviewed_files` is the set of
    normalized paths that already carry a Claude Review thread, and `signatures`
    is the set of ``(normalized_path, normalized_comment)`` pairs across both the
    inline threads and the PR-level Claude Review notes.
    """
    reviewed_files = set()
    signatures = set()

    for thread in threads:
        if not is_claude_review_thread(thread):
            continue
        path = normalize_path(thread.get("path", ""))
        if path:
            reviewed_files.add(path)
        normalized = normalize_comment(thread.get("body", ""))
        if normalized:
            signatures.add((path, normalized))

    for comment in issue_comments:
        body = comment.get("body", "")
        if "[Claude Review" not in body:
            continue
        fallback_path, _ = parse_fallback_location(body)
        path = normalize_path(fallback_path or "")
        normalized = normalize_comment(body)
        if normalized:
            signatures.add((path, normalized))

    return reviewed_files, signatures


def get_check_id_threads(threads):
    """Map check_id -> thread info for existing Claude Review threads."""
    mapping = {}
    for thread in threads:
        if not is_claude_review_thread(thread):
            continue
        body = thread.get("body", "")
        check_id = extract_check_id(body)
        comments = thread.get("comments", [])
        if check_id and comments:
            mapping[check_id] = {
                "thread_id": thread.get("id"),
                "comment_id": comments[0].get("databaseId"),
                "body": body,
                "isResolved": thread.get("isResolved", False),
                "path": thread.get("path", ""),
            }
    return mapping


def select_threads_to_resolve(threads, bot_login):
    """Return node-ids of unresolved Claude Review threads with a human reply.

    A human reply is any comment after the first whose author is not the bot.
    When `bot_login` is unknown, bot and human replies are indistinguishable, so
    nothing is resolved (fail safe).
    """
    if not bot_login:
        return []
    to_resolve = []
    for thread in threads:
        if not is_claude_review_thread(thread):
            continue
        if thread.get("isResolved"):
            continue
        for comment in thread.get("comments", [])[1:]:
            login = comment.get("author_login", "")
            if login and login != bot_login:
                to_resolve.append(thread.get("id"))
                break
    return to_resolve


# --------------------------------------------------------------------------- #
# Thin I/O wrappers (network)
# --------------------------------------------------------------------------- #

def _parse_json(raw):
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        return raw


def _http(method, url, token, body=None):
    """Perform an authenticated HTTP request, returning ``(status, data)``.

    Never raises for HTTP errors — the status is returned so callers can branch
    (e.g. 422 inline-comment fallback). Retries once on 5xx and on a 403 that
    carries a `Retry-After` (secondary rate limit).
    """
    payload = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": API_VERSION,
        "User-Agent": USER_AGENT,
    }
    if payload is not None:
        headers["Content-Type"] = "application/json"

    attempts = 0
    while True:
        attempts += 1
        req = urllib.request.Request(url, data=payload, headers=headers, method=method)
        try:
            resp = urllib.request.urlopen(req)
            return resp.getcode(), _parse_json(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            raw = ""
            try:
                raw = e.read().decode("utf-8")
            except Exception:
                pass
            retry_after = e.headers.get("Retry-After") if e.headers else None
            transient = e.code >= 500 or (e.code == 403 and retry_after)
            if attempts < MAX_RETRIES and transient:
                delay = int(retry_after) if (retry_after and retry_after.isdigit()) else RETRY_BACKOFF
                time.sleep(min(delay, MAX_RETRY_SLEEP))
                continue
            return e.code, _parse_json(raw)
        except urllib.error.URLError as e:
            if attempts < MAX_RETRIES:
                time.sleep(RETRY_BACKOFF)
                continue
            print(f"Network error for {method} {url} -- {e}")
            return 0, None


def gh_rest(method, path, token, body=None):
    status, data = _http(method, API_BASE + path, token, body)
    if method != "GET":
        time.sleep(REQUEST_DELAY)
    return status, data


def gh_graphql(query, variables, token):
    status, data = _http("POST", GRAPHQL_URL, token, {"query": query, "variables": variables})
    time.sleep(REQUEST_DELAY)
    if isinstance(data, dict):
        if data.get("errors"):
            print(f"GraphQL errors: {data['errors']}")
        return data.get("data") or {}
    return {}


_REVIEW_THREADS_QUERY = """
query($owner:String!, $repo:String!, $number:Int!, $cursor:String) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$number) {
      reviewThreads(first:50, after:$cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          isResolved
          comments(first:100) {
            nodes { databaseId body path author { login } }
          }
        }
      }
    }
  }
}
"""


def _thread_from_node(node):
    comments = []
    for c in (node.get("comments", {}) or {}).get("nodes", []) or []:
        author = c.get("author") or {}
        comments.append({
            "databaseId": c.get("databaseId"),
            "body": c.get("body", "") or "",
            "path": c.get("path", "") or "",
            "author_login": author.get("login", "") or "",
        })
    first = comments[0] if comments else {}
    return {
        "id": node.get("id"),
        "isResolved": bool(node.get("isResolved")),
        "comments": comments,
        "path": first.get("path", ""),
        "body": first.get("body", ""),
    }


def list_review_threads_graphql(owner, repo, pr_number, token):
    """Fetch all review threads on the PR (paginated), as internal dicts."""
    threads = []
    cursor = None
    while True:
        variables = {"owner": owner, "repo": repo, "number": int(pr_number), "cursor": cursor}
        data = gh_graphql(_REVIEW_THREADS_QUERY, variables, token)
        try:
            rt = data["repository"]["pullRequest"]["reviewThreads"]
        except (KeyError, TypeError):
            break
        for node in rt.get("nodes", []) or []:
            threads.append(_thread_from_node(node))
        page = rt.get("pageInfo", {}) or {}
        if page.get("hasNextPage"):
            cursor = page.get("endCursor")
        else:
            break
    return threads


def list_issue_comments(owner, repo, pr_number, token):
    """Fetch all PR-level (issue) comments via REST (paginated)."""
    comments = []
    page = 1
    while True:
        path = f"/repos/{owner}/{repo}/issues/{pr_number}/comments?per_page=100&page={page}"
        status, data = gh_rest("GET", path, token)
        if status != 200 or not isinstance(data, list):
            break
        for c in data:
            author = c.get("user") or {}
            comments.append({
                "id": c.get("id"),
                "body": c.get("body", "") or "",
                "author_login": author.get("login", "") or "",
            })
        if len(data) < 100:
            break
        page += 1
    return comments


def create_inline_comment(owner, repo, pr_number, body, commit_id, path, line, token):
    """Create an inline review comment; returns ``(ok, status)`` to branch on 422."""
    payload = {"body": body, "commit_id": commit_id, "path": path, "line": line, "side": "RIGHT"}
    status, _ = gh_rest("POST", f"/repos/{owner}/{repo}/pulls/{pr_number}/comments", token, payload)
    return (200 <= status < 300, status)


def create_issue_comment(owner, repo, pr_number, body, token):
    status, _ = gh_rest("POST", f"/repos/{owner}/{repo}/issues/{pr_number}/comments", token, {"body": body})
    return 200 <= status < 300


def patch_comment(kind, owner, repo, comment_id, body, token):
    if kind == "inline":
        path = f"/repos/{owner}/{repo}/pulls/comments/{comment_id}"
    else:
        path = f"/repos/{owner}/{repo}/issues/comments/{comment_id}"
    status, _ = gh_rest("PATCH", path, token, {"body": body})
    return 200 <= status < 300


_RESOLVE_MUTATION = """
mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { id isResolved } } }
"""
_UNRESOLVE_MUTATION = """
mutation($id:ID!) { unresolveReviewThread(input:{threadId:$id}) { thread { id isResolved } } }
"""


def resolve_thread(thread_id, token):
    gh_graphql(_RESOLVE_MUTATION, {"id": thread_id}, token)


def unresolve_thread(thread_id, token):
    gh_graphql(_UNRESOLVE_MUTATION, {"id": thread_id}, token)


def submit_approval(owner, repo, pr_number, commit_id, token):
    """Cast an APPROVE review as the bot identity. Never REQUEST_CHANGES."""
    payload = {"event": "APPROVE"}
    if commit_id:
        payload["commit_id"] = commit_id
    status, _ = gh_rest("POST", f"/repos/{owner}/{repo}/pulls/{pr_number}/reviews", token, payload)
    return 200 <= status < 300


def get_head_sha(owner, repo, pr_number, token):
    status, data = gh_rest("GET", f"/repos/{owner}/{repo}/pulls/{pr_number}", token)
    if status == 200 and isinstance(data, dict):
        return (data.get("head") or {}).get("sha", "")
    return ""


def get_bot_login(token):
    status, data = gh_rest("GET", "/user", token)
    if status == 200 and isinstance(data, dict):
        return data.get("login", "")
    return ""


# --------------------------------------------------------------------------- #
# Orchestration
# --------------------------------------------------------------------------- #

def main():
    claude_issues = []
    if os.path.exists(REVIEW_FILE):
        try:
            with open(REVIEW_FILE) as f:
                raw = f.read()
            claude_issues = extract_review_from_claude_output(raw)
        except (json.JSONDecodeError, ValueError) as e:
            print(f"Review output is not valid JSON ({e}), skipping Claude review.")
    else:
        print("No Claude review results file found.")

    review = claude_issues
    print(f"Total issues: {len(review)}")

    token = os.environ.get("GH_REVIEW_PAT", "")
    repo_full = os.environ.get("GITHUB_REPOSITORY", "")
    pr_number = os.environ.get("PR_NUMBER", "")
    head_sha = os.environ.get("HEAD_SHA", "")
    bot_login = os.environ.get("GH_BOT_LOGIN", "")

    if not all([token, repo_full, pr_number]) or "/" not in repo_full:
        print("Missing required environment (GH_REVIEW_PAT, GITHUB_REPOSITORY=owner/repo, PR_NUMBER)")
        return
    owner, repo = repo_full.split("/", 1)

    if not bot_login:
        bot_login = get_bot_login(token)
    print(f"Bot identity: {bot_login or '(unknown — resolve/dedup degraded)'}")

    if not head_sha:
        head_sha = get_head_sha(owner, repo, pr_number, token)
    if not head_sha:
        print("Warning: could not determine HEAD SHA; inline comments and approval may fail.")

    # --- Step 1: Fetch threads (GraphQL) + PR-level comments (REST) ---
    threads = list_review_threads_graphql(owner, repo, pr_number, token)
    issue_comments = list_issue_comments(owner, repo, pr_number, token)
    print(f"Found {len(threads)} review thread(s) and {len(issue_comments)} PR-level comment(s)")

    # --- Step 2: Auto-resolve threads with a human reply ---
    closed = 0
    for thread_id in select_threads_to_resolve(threads, bot_login):
        resolve_thread(thread_id, token)
        closed += 1
        print(f"Auto-resolved thread {thread_id} (human reply)")

    # --- Step 3: Build deduplication sets ---
    reviewed_files, existing_signatures = build_signatures(threads, issue_comments)
    print(f"Files already reviewed: {len(reviewed_files)} -- {reviewed_files or '(none)'}")
    print(f"Existing comment signatures: {len(existing_signatures)}")
    check_id_threads = get_check_id_threads(threads)
    matched_check_ids = set()

    # --- Step 4: Separate check_id issues from regular issues ---
    meaningful_issues = [
        item for item in review
        if item.get("comment") and item.get("comment") != "No details"
    ]
    check_id_issues = [i for i in meaningful_issues if i.get("check_id")]
    regular_issues = [i for i in meaningful_issues if not i.get("check_id")]

    # --- Step 5: check_id update/skip/create + resolve stale (dormant) ---
    check_id_posted = check_id_updated = check_id_skipped = check_id_resolved = 0
    for item in check_id_issues:
        check_id = item["check_id"]
        matched_check_ids.add(check_id)
        severity = item.get("severity", "info")
        comment = item.get("comment", "No details")
        path = normalize_path(item.get("file", ""))
        line = item.get("line")
        body = build_comment_body(severity, comment, check_id=check_id)

        existing = check_id_threads.get(check_id)
        if existing:
            if normalize_comment(existing["body"]) == normalize_comment(body):
                check_id_skipped += 1
                continue
            if patch_comment("inline", owner, repo, existing["comment_id"], body, token):
                if existing["isResolved"]:
                    unresolve_thread(existing["thread_id"], token)
                check_id_updated += 1
                print(f"Updated check_id '{check_id}'")
        elif path and line:
            ok, status = create_inline_comment(owner, repo, pr_number, body, head_sha, path, _as_int(line), token)
            if ok:
                check_id_posted += 1
            elif status == 422:
                fb = build_comment_body(severity, comment, check_id=check_id, location=f"{path}:{line}")
                if create_issue_comment(owner, repo, pr_number, fb, token):
                    check_id_posted += 1
        else:
            if create_issue_comment(owner, repo, pr_number, body, token):
                check_id_posted += 1

    for check_id, info in check_id_threads.items():
        if check_id not in matched_check_ids and not info["isResolved"]:
            resolve_thread(info["thread_id"], token)
            check_id_resolved += 1

    # --- Step 6: Filter regular issues by file + comment dedup ---
    new_issues = []
    skipped_file = skipped_duplicate = 0
    for item in regular_issues:
        path = normalize_path(item.get("file", ""))
        comment = item.get("comment", "")
        if is_duplicate_comment(path, comment, existing_signatures):
            skipped_duplicate += 1
            continue
        if path and path in reviewed_files:
            skipped_file += 1
            continue
        new_issues.append(item)

    print(
        f"Issues: {len(meaningful_issues)} total, {len(new_issues)} to post, "
        f"{skipped_file} skipped (file reviewed), {skipped_duplicate} skipped (duplicate)"
    )

    # --- Step 7: Approve when clean, else post findings ---
    has_active_check_id = check_id_posted > 0 or check_id_updated > 0
    if not new_issues and not has_active_check_id:
        approved = submit_approval(owner, repo, pr_number, head_sha, token)
        print(f"Approval {'succeeded' if approved else 'failed'} on PR #{pr_number}")
        note = (
            "✅ **Claude Code reviewed and approved** -- no issues found."
            if approved
            else "✅ **Claude Code reviewed** -- no issues found."
        )
        if _clean_note_present(issue_comments, bot_login):
            print("Clean-review note already present; not re-posting.")
        else:
            create_issue_comment(owner, repo, pr_number, note, token)
        print(
            f"\nSummary: 0 new comment(s) posted, approved={approved}, "
            f"{check_id_resolved} check_id thread(s) auto-resolved, {closed} thread(s) auto-resolved"
        )
        return

    posted = fallback = pr_level = 0
    for item in new_issues:
        if posted + fallback + pr_level >= MAX_INLINE_COMMENTS:
            print(f"Reached MAX_INLINE_COMMENTS ({MAX_INLINE_COMMENTS}); deferring the rest.")
            break
        severity = item.get("severity", "info")
        comment = item.get("comment", "No details")
        path = normalize_path(item.get("file", ""))
        line = item.get("line")
        body = build_comment_body(severity, comment)

        if path and line is not None and head_sha:
            ok, status = create_inline_comment(owner, repo, pr_number, body, head_sha, path, _as_int(line), token)
            if ok:
                posted += 1
                print(f"Posted {severity} inline on {path}:{line}")
            elif status == 422:
                fb = build_comment_body(severity, comment, location=f"{path}:{line}")
                if create_issue_comment(owner, repo, pr_number, fb, token):
                    fallback += 1
                    print(f"Inline 422 — posted fallback note for {path}:{line}")
            else:
                print(f"Failed to post on {path}:{line} -- HTTP {status}")
        else:
            location = path or None
            fb = build_comment_body(severity, comment, location=location)
            if create_issue_comment(owner, repo, pr_number, fb, token):
                pr_level += 1
                print(f"Posted {severity} PR-level note for {path or '(no file)'}")

    print(
        f"\nSummary: {posted} inline + {fallback} fallback + {pr_level} PR-level comment(s) posted, "
        f"{check_id_posted} check_id created, {check_id_updated} check_id updated, "
        f"{check_id_skipped} check_id unchanged, {check_id_resolved} check_id auto-resolved, "
        f"{skipped_file} skipped (file reviewed), {skipped_duplicate} skipped (duplicate), "
        f"{closed} thread(s) auto-resolved"
    )


def _as_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return value


def _clean_note_present(issue_comments, bot_login):
    """True if a bot-authored clean-review note already exists (anti-spam guard)."""
    for comment in issue_comments:
        if "Claude Code reviewed" not in comment.get("body", ""):
            continue
        author = comment.get("author_login", "")
        if not bot_login or author == bot_login:
            return True
    return False


if __name__ == "__main__":
    main()
