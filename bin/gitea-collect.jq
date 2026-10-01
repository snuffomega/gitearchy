# gitea-collect.jq — Transform raw API data into the overview structure
# Supports Gitea >= 1.19. Actions runs require >= 1.20.
# Input: --arg url, --arg user, --arg ts,
#        --argjson/--slurpfile prs, --argjson/--slurpfile runs, --argjson repo_count,
#        --argjson max_stale, --argjson repo_failed, --argjson repo_attempted,
#        --argjson incomplete, --argjson carried, --argjson carried_repos,
#        --argjson failed_resources

# Latest effective review per reviewer: last non-COMMENT, non-DISMISSED review wins.
# This prevents a stale REQUEST_CHANGES from blocking after the reviewer approves.
def latest_reviews_per_reviewer:
  if type == "array" then
    [ .[] | select(.state != null and .state != "" and .state != "COMMENT" and .state != "DISMISSED") ]
    | sort_by(.submitted_at // .id // 0)
    | reduce .[] as $r ({}; .[$r.user.login] = $r)
    | [.[]]
  else [] end;

def review_summary:
  if type == "array" then
    latest_reviews_per_reviewer as $effective |
    {
      approved: [$effective[] | select(.state == "APPROVED")] | length,
      changes_requested: [$effective[] | select(.state == "REQUEST_CHANGES" or .state == "CHANGES_REQUESTED")] | length,
      pending: [$effective[] | select(.state == "PENDING")] | length,
      reviewers: [$effective[] | .user.login] | unique,
      all_reviewers: [.[] | .user.login] | unique
    }
  else
    { approved: 0, changes_requested: 0, pending: 0, reviewers: [], all_reviewers: [] }
  end;

# The collector loads potentially large arrays from files to avoid the
# operating system's command-line argument limit. Unit tests pass arrays with
# --argjson, so accept both the direct and slurpfile-wrapped representations.
def unwrap_slurpfile:
  if type == "array" and length == 1 and (.[0] | type) == "array" then .[0]
  else .
  end;

def ci_summary:
  if type == "object" and .statuses then
    {
      state: (.state // "unknown"),
      total: (.total_count // 0),
      checks: [(.statuses // [])[] | {
        context: .context,
        state: .status,
        description: .description,
        target_url: .target_url,
        created: .created_at
      }],
      passed: [(.statuses // [])[] | select(.status == "success")] | length,
      failed: [(.statuses // [])[] | select(.status == "failure" or .status == "error")] | length,
      pending_count: [(.statuses // [])[] | select(.status == "pending")] | length
    }
  else
    { state: "unknown", total: 0, checks: [], passed: 0, failed: 0, pending_count: 0 }
  end;

# Mergeability: Gitea returns null when not yet computed, true/false when known.
# null is treated as "unknown" — never assume mergeable.
def is_mergeable:
  .mergeable == true;

def is_conflicted:
  .mergeable == false;

def mergeable_unknown:
  .mergeable == null or (.mergeable | type) != "boolean";

def is_draft:
  .draft == true;

def pr_attention($user):
  .reviews.changes_requested > 0
  or (.ci.state == "failure" or .ci.state == "error")
  or (.requested_reviewers // [] | index($user) != null);

def pr_status_label($user):
  if .ci.state == "failure" or .ci.state == "error" then "ci_failed"
  elif .reviews.changes_requested > 0 then "changes_requested"
  elif (.requested_reviewers // [] | index($user) != null) then "review_requested"
  elif .ci.state == "pending" and .ci.total > 0 then "ci_running"
  elif is_draft then "draft"
  elif is_conflicted then "conflicted"
  elif .reviews.approved > 0 and .ci.state == "success" then "approved_ci_passed"
  elif .reviews.approved > 0 then "approved"
  elif .ci.state == "success" then "ci_passed"
  else "open"
  end;

def blocker_reason($user):
  [
    (if is_draft then "Draft PR" else empty end),
    (if .ci.failed > 0 then
      (.ci.checks | map(select(.state == "failure" or .state == "error")) | map(.context) | join(", "))
      | if . != "" then "CI failed: " + . else empty end
    else empty end),
    (if .reviews.changes_requested > 0 then
      "Changes requested by reviewer"
    else empty end),
    (if is_conflicted then
      "Merge conflicts"
    else empty end),
    (if mergeable_unknown and (is_draft | not) then
      "Mergeability unknown"
    else empty end),
    (if .reviews.approved == 0 and (.requested_reviewers // [] | length) > 0 then
      "Awaiting review"
    else empty end)
  ] | if length > 0 then join("; ") else null end;

# Gitea Actions uses lifecycle values such as queued/in_progress/completed in
# status and the result (success/failure/etc.) in conclusion. Older releases
# also returned result values directly in status, so accept both shapes.
def run_status_bucket:
  if .status == "running" or .status == "waiting" or .status == "queued"
     or .status == "in_progress" or .status == "pending" or .status == "requested" then "running"
  elif .status == "completed" then
    if .conclusion == "failure" or .conclusion == "error" or .conclusion == "cancelled"
       or .conclusion == "timed_out" or .conclusion == "action_required"
       or .conclusion == "startup_failure" or .conclusion == "stale" or .conclusion == "skipped"
    then "failed"
    else "completed"
    end
  elif .status == "success" then "completed"
  elif .status == "failure" or .status == "error" or .status == "cancelled"
       or .status == "timed_out" or .status == "skipped" then "failed"
  else "other"
  end;

# Transform PRs
($prs | unwrap_slurpfile | map({
  id: .number,
  repo: ._repo,
  title: .title,
  branch: .head.ref,
  base: .base.ref,
  author: .user.login,
  author_avatar: .user.avatar_url,
  created: .created_at,
  updated: .updated_at,
  url: .html_url,
  mergeable: .mergeable,
  draft: (if .draft == true then true else false end),
  labels: [(.labels // [])[] | { name: .name, color: .color }],
  requested_reviewers: [(.requested_reviewers // [])[] | .login],
  reviews: (._review_summary // (._reviews | review_summary)),
  ci: (._ci_summary // (._commit_status | ci_summary)),
  head_sha: .head.sha
})) as $processed_prs |

# Classify each PR
($processed_prs | map(
  . + {
    status_label: pr_status_label($user),
    needs_attention: pr_attention($user),
    blocker: blocker_reason($user)
  }
)) as $classified_prs |

# Transform runs — use fields from Gitea Actions API (>= 1.20)
($runs | unwrap_slurpfile | map({
  id: .id,
  repo: ._repo,
  workflow: (.name // .display_title // .path // .workflow_id // "unknown"),
  status: .status,
  conclusion: (.conclusion // .status),
  branch: (.head_branch // .head_sha),
  event: .event,
  started: (.run_started_at // .started_at // .created_at),
  updated: (.updated_at // .completed_at // .started_at // .created_at),
  url: .html_url,
  bucket: run_status_bucket
})) as $processed_runs |

# Build categorized buckets
{
  meta: {
    gitea_url: $url,
    username: $user,
    collected_at: $ts,
    repo_count: $repo_count,
    repo_failed: $repo_failed,
    repo_attempted: $repo_attempted,
    incomplete: $incomplete,
    carried: $carried,
    carried_repos: $carried_repos,
    failed_resources: $failed_resources,
    stale: $incomplete,
    max_stale_hours: $max_stale
  },
  summary: {
    needs_attention: [$classified_prs[] | select(.needs_attention)] | length,
    review_requested: [$classified_prs[] | select(.status_label == "review_requested")] | length,
    ci_failed: [$classified_prs[] | select(.status_label == "ci_failed")] | length,
    changes_requested: [$classified_prs[] | select(.status_label == "changes_requested")] | length,
    running_jobs: [$processed_runs[] | select(.bucket == "running")] | length,
    open_prs: ($classified_prs | length),
    ready_to_merge: [$classified_prs[] | select(.status_label == "approved_ci_passed")] | length
  },
  sections: {
    attention: [$classified_prs[] | select(.needs_attention)] | sort_by(.updated) | reverse,
    running: [$processed_runs[] | select(.bucket == "running")] | sort_by(.updated) | reverse,
    recently_completed: (
      ([$processed_runs[] | select(.bucket == "completed" or .bucket == "failed")]
       | sort_by(.updated) | reverse | .[0:20])
    ),
    my_prs: [$classified_prs[] | select(.author == $user)] | sort_by(.updated) | reverse,
    review_queue: [$classified_prs[] | select(
      .requested_reviewers | index($user) != null
    )] | sort_by(.updated) | reverse,
    all_prs: $classified_prs | sort_by(.updated) | reverse
  },
  repos: (($classified_prs | map(.repo)) + ($processed_runs | map(.repo)) | unique | sort)
}
