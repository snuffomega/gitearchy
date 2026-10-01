#!/usr/bin/env bash
# Writes a demo snapshot to stdout: generic acme/* repos run through the real
# collector transform, with times relative to now so cards read "Nm ago".
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JQ_SCRIPT="$HERE/../../bin/gitea-collect.jq"

ago() { date -u -d "-$1 minutes" +%Y-%m-%dT%H:%M:%SZ; }

status() { # state, passed, total
  jq -n --arg s "$1" --argjson p "$2" --argjson t "$3" '{
    state: $s, total_count: $t,
    statuses: ([range(0; $p)] | map({context: "ci/check", status: "success", description: "Passed"}))
      + (["integration-tests", "lint", "build", "e2e"][0:($t - $p)]
         | map({context: ., status: $s, description: "Failed"}))
  }'
}

pr() { # repo, number, title, author, branch, minutes-ago, draft, mergeable, reviewers-json, reviews-json, status-json, labels-json
  jq -n --arg repo "$1" --argjson n "$2" --arg title "$3" --arg author "$4" --arg branch "$5" \
    --arg at "$(ago "$6")" --argjson draft "$7" --argjson mergeable "$8" \
    --argjson reviewers "$9" --argjson reviews "${10}" --argjson status "${11}" --argjson labels "${12}" '{
    number: $n, title: $title, state: "open", draft: $draft, mergeable: $mergeable,
    user: {login: $author}, head: {ref: $branch, sha: "0000000"}, base: {ref: "main"},
    created_at: $at, updated_at: $at,
    html_url: "https://git.example.com/\($repo)/pulls/\($n)",
    labels: $labels, requested_reviewers: ($reviewers | map({login: .})),
    _reviews: $reviews, _commit_status: $status, _repo: $repo
  }'
}

review() { jq -n --arg u "$1" --arg s "$2" --arg at "$(ago "$3")" '[{id: 1, user: {login: $u}, state: $s, submitted_at: $at}]'; }

prs=$(jq -s '.' <(
  pr acme/api 128 "Fix connection pool exhaustion under load" demo fix/pool-exhaustion 6 false true \
    '[]' '[]' "$(status failure 9 12)" '[{"name":"bug","color":"e99695"}]'
  pr acme/storefront 342 "Add address autocomplete to checkout" alex feat/address-autocomplete 18 false true \
    '["demo"]' '[]' "$(status success 14 14)" '[]'
  pr acme/docs 57 "Document the v2 webhooks API" demo docs/webhooks-v2 47 false true \
    '[]' "$(review sam REQUEST_CHANGES 30)" "$(status success 3 3)" '[{"name":"docs","color":"84b6eb"}]'
  pr acme/storefront 339 "Cache product images at the edge" demo perf/edge-image-cache 95 false true \
    '[]' "$(review alex APPROVED 60)" "$(status success 14 14)" '[]'
  pr acme/api 131 "Rate-limit the public endpoints" demo feat/rate-limit 180 true null \
    '[]' '[]' '{}' '[]'
))

run() { # repo, id, name, status, conclusion, branch, minutes-ago
  jq -n --arg repo "$1" --argjson id "$2" --arg name "$3" --arg status "$4" --arg conclusion "$5" \
    --arg branch "$6" --arg at "$(ago "$7")" '{
    id: $id, name: $name, status: $status,
    conclusion: (if $conclusion == "" then null else $conclusion end),
    head_branch: $branch, event: "pull_request", run_started_at: $at, updated_at: $at,
    html_url: "https://git.example.com/\($repo)/actions/runs/\($id)", _repo: $repo
  }'
}

runs=$(jq -s '.' <(
  run acme/storefront 9011 "CI" in_progress "" feat/address-autocomplete 2
  run acme/api 9007 "CI" completed failure fix/pool-exhaustion 6
  run acme/storefront 9004 "CI" completed success perf/edge-image-cache 90
  run acme/docs 9002 "Docs preview" completed success docs/webhooks-v2 45
))

jq -n \
  --arg url "https://git.example.com" \
  --arg user "demo" \
  --arg ts "$(ago 1)" \
  --argjson prs "$prs" \
  --argjson runs "$runs" \
  --argjson repo_count 3 \
  --argjson max_stale 6 \
  --argjson repo_failed 0 \
  --argjson repo_attempted 3 \
  --argjson incomplete false \
  --argjson carried false \
  --argjson carried_repos "[]" \
  --argjson failed_resources "{}" \
  -f "$JQ_SCRIPT" | jq '.known_repos = .repos'
