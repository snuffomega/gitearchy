#!/usr/bin/env bash
# Test the jq transform against mock data — no network or credentials needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK_DIR="$SCRIPT_DIR/mock-responses"
JQ_SCRIPT="$SCRIPT_DIR/../bin/gitea-collect.jq"
PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

assert_neq() {
  local desc="$1" unexpected="$2" actual="$3"
  if [ "$unexpected" != "$actual" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (should not be '$unexpected')"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qi "$needle"; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected to contain '$needle')"
    FAIL=$((FAIL + 1))
  fi
}

assert_gt() {
  local desc="$1" threshold="$2" actual="$3"
  if [ "$actual" -gt "$threshold" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected > $threshold, got $actual)"
    FAIL=$((FAIL + 1))
  fi
}

run_jq() {
  local test_prs="$1" test_runs="$2"
  jq -n \
    --arg url "https://git.example.com" \
    --arg user "testuser" \
    --arg ts "2026-09-15T10:00:00Z" \
    --argjson prs "$test_prs" \
    --argjson runs "$test_runs" \
    --argjson repo_count 3 \
    --argjson max_stale 6 \
    --argjson repo_failed 0 \
    --argjson repo_attempted 3 \
    --argjson incomplete false \
    --argjson carried false \
    --argjson carried_repos "[]" \
    --argjson failed_resources "{}" \
    -f "$JQ_SCRIPT"
}

# Build mock PR data with embedded reviews and commit status
build_test_prs() {
  local prs reviews_approved reviews_changes status_ok status_fail

  prs=$(cat "$MOCK_DIR/pulls.json")
  reviews_approved=$(cat "$MOCK_DIR/reviews.json")
  reviews_changes=$(cat "$MOCK_DIR/reviews-changes.json")
  status_ok=$(cat "$MOCK_DIR/commit-status-success.json")
  status_fail=$(cat "$MOCK_DIR/commit-status-failure.json")

  # PR #42: approved reviews + successful CI + mergeable=true
  # PR #43: changes requested + failed CI + mergeable=true
  # PR #10: draft, no reviews, no CI, mergeable=true
  # PR #44: no reviews, no CI, mergeable=false (conflicted)
  # PR #45: no reviews, no CI, mergeable=null (unknown)
  echo "$prs" | jq \
    --argjson rev_ok "$reviews_approved" \
    --argjson rev_chg "$reviews_changes" \
    --argjson ci_ok "$status_ok" \
    --argjson ci_fail "$status_fail" \
    '
    .[0]._reviews = $rev_ok | .[0]._commit_status = $ci_ok | .[0]._repo = "testuser/webapp" |
    .[1]._reviews = $rev_chg | .[1]._commit_status = $ci_fail | .[1]._repo = "testuser/webapp" |
    .[2]._reviews = [] | .[2]._commit_status = {} | .[2]._repo = "testuser/api-server" |
    .[3]._reviews = [] | .[3]._commit_status = {} | .[3]._repo = "testuser/webapp" |
    .[4]._reviews = [] | .[4]._commit_status = {} | .[4]._repo = "testuser/webapp"
    '
}

build_test_runs() {
  cat "$MOCK_DIR/action-runs.json" | jq '[.workflow_runs[] | . + {"_repo": "testuser/webapp"}]'
}

echo "=== Gitearchy: JQ Transform Tests ==="
echo ""

test_prs=$(build_test_prs)
test_runs=$(build_test_runs)
output=$(run_jq "$test_prs" "$test_runs")

# --- Test 1: Basic structure ---
echo "Test 1: Output structure"
assert_eq "has meta" "true" "$(echo "$output" | jq 'has("meta")')"
assert_eq "has summary" "true" "$(echo "$output" | jq 'has("summary")')"
assert_eq "has sections" "true" "$(echo "$output" | jq 'has("sections")')"
assert_eq "has repos" "true" "$(echo "$output" | jq 'has("repos")')"
assert_eq "meta.username" "testuser" "$(echo "$output" | jq -r '.meta.username')"
assert_eq "meta.gitea_url" "https://git.example.com" "$(echo "$output" | jq -r '.meta.gitea_url')"
assert_eq "meta.repo_failed" "0" "$(echo "$output" | jq '.meta.repo_failed')"
assert_eq "meta.repo_attempted" "3" "$(echo "$output" | jq '.meta.repo_attempted')"

echo ""

# --- Test 2: PR classification ---
echo "Test 2: PR classification"
pr42_status=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 42) | .status_label')
pr43_status=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 43) | .status_label')
pr10_status=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 10) | .status_label')
pr44_status=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 44) | .status_label')
pr45_status=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 45) | .status_label')

assert_eq "PR #42 (approved + CI pass + mergeable) = approved_ci_passed" "approved_ci_passed" "$pr42_status"
assert_eq "PR #43 (changes req + CI fail) = ci_failed" "ci_failed" "$pr43_status"
assert_eq "PR #10 (draft) = draft" "draft" "$pr10_status"
assert_eq "PR #44 (mergeable=false) = conflicted" "conflicted" "$pr44_status"
assert_eq "PR #45 (no reviews, no CI, mergeable=null) = open" "open" "$pr45_status"

echo ""

# --- Test 3: Drafts never ready (regression) ---
echo "Test 3: Drafts never classified as ready"
# Give the draft PR approvals + CI pass — it should still be 'draft'
draft_prs=$(cat "$MOCK_DIR/pulls.json" | jq \
  --argjson rev_ok "$(cat "$MOCK_DIR/reviews.json")" \
  --argjson ci_ok "$(cat "$MOCK_DIR/commit-status-success.json")" \
  '[.[2] | ._reviews = $rev_ok | ._commit_status = $ci_ok | ._repo = "testuser/api-server"]')
draft_output=$(run_jq "$draft_prs" "[]")
draft_status=$(echo "$draft_output" | jq -r '.sections.all_prs[0].status_label')
assert_eq "draft with approvals + CI pass = draft" "draft" "$draft_status"
assert_neq "draft never approved_ci_passed" "approved_ci_passed" "$draft_status"

echo ""

# --- Test 4: Conflicted never ready (regression) ---
echo "Test 4: Conflicted PRs never ready"
conflict_prs=$(cat "$MOCK_DIR/pulls.json" | jq \
  --argjson rev_ok "$(cat "$MOCK_DIR/reviews.json")" \
  --argjson ci_ok "$(cat "$MOCK_DIR/commit-status-success.json")" \
  '[.[3] | ._reviews = $rev_ok | ._commit_status = $ci_ok | ._repo = "testuser/webapp"]')
conflict_output=$(run_jq "$conflict_prs" "[]")
conflict_status=$(echo "$conflict_output" | jq -r '.sections.all_prs[0].status_label')
assert_eq "conflicted with approvals + CI pass = conflicted" "conflicted" "$conflict_status"

echo ""

# --- Test 5: mergeable=null with approved + CI success ---
echo "Test 5: Unknown mergeability still approved_ci_passed"
null_merge_prs=$(cat "$MOCK_DIR/pulls.json" | jq \
  --argjson rev_ok "$(cat "$MOCK_DIR/reviews.json")" \
  --argjson ci_ok "$(cat "$MOCK_DIR/commit-status-success.json")" \
  '[.[4] | ._reviews = $rev_ok | ._commit_status = $ci_ok | ._repo = "testuser/webapp"]')
null_merge_output=$(run_jq "$null_merge_prs" "[]")
null_merge_status=$(echo "$null_merge_output" | jq -r '.sections.all_prs[0].status_label')
assert_eq "mergeable=null with approved+CI = approved_ci_passed" "approved_ci_passed" "$null_merge_status"
blocker=$(echo "$null_merge_output" | jq -r '.sections.all_prs[0].blocker // ""')
assert_contains "has blocker about mergeability" "ergeab" "$blocker"

echo ""

# --- Test 6: Latest review per reviewer (regression) ---
echo "Test 6: Latest review per reviewer"
superseded_reviews=$(cat "$MOCK_DIR/reviews-superseded.json")
# reviewer1 first requested changes, then approved — only approval should count
superseded_prs=$(cat "$MOCK_DIR/pulls.json" | jq \
  --argjson revs "$superseded_reviews" \
  --argjson ci_ok "$(cat "$MOCK_DIR/commit-status-success.json")" \
  '[.[0] | ._reviews = $revs | ._commit_status = $ci_ok | ._repo = "testuser/webapp"]')
superseded_output=$(run_jq "$superseded_prs" "[]")
superseded_approved=$(echo "$superseded_output" | jq '.sections.all_prs[0].reviews.approved')
superseded_changes=$(echo "$superseded_output" | jq '.sections.all_prs[0].reviews.changes_requested')
assert_eq "superseded: approved count = 1" "1" "$superseded_approved"
assert_eq "superseded: changes_requested count = 0" "0" "$superseded_changes"
superseded_status=$(echo "$superseded_output" | jq -r '.sections.all_prs[0].status_label')
assert_eq "superseded review -> approved_ci_passed" "approved_ci_passed" "$superseded_status"

echo ""

# --- Test 7: Attention items ---
echo "Test 7: Attention items"
attention_count=$(echo "$output" | jq '.sections.attention | length')
assert_gt "attention items exist" 0 "$attention_count"
pr43_attention=$(echo "$output" | jq '[.sections.attention[] | select(.id == 43)] | length')
assert_eq "PR #43 in attention (CI failed)" "1" "$pr43_attention"

echo ""

# --- Test 8: Blocker reasons ---
echo "Test 8: Blocker reasons"
pr43_blocker=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 43) | .blocker')
assert_neq "PR #43 has blocker" "null" "$pr43_blocker"
pr44_blocker=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 44) | .blocker')
echo "$pr44_blocker" | grep -qi "conflict" && {
  echo "  PASS: PR #44 blocker mentions conflicts"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL: PR #44 blocker should mention conflicts (got: $pr44_blocker)"
  FAIL=$((FAIL + 1))
}
pr10_blocker=$(echo "$output" | jq -r '.sections.all_prs[] | select(.id == 10) | .blocker')
echo "$pr10_blocker" | grep -qi "draft" && {
  echo "  PASS: PR #10 blocker mentions draft"
  PASS=$((PASS + 1))
} || {
  echo "  FAIL: PR #10 blocker should mention draft (got: $pr10_blocker)"
  FAIL=$((FAIL + 1))
}

echo ""

# --- Test 9: Review summaries ---
echo "Test 9: Review summaries"
pr42_approved=$(echo "$output" | jq '.sections.all_prs[] | select(.id == 42) | .reviews.approved')
pr43_changes=$(echo "$output" | jq '.sections.all_prs[] | select(.id == 43) | .reviews.changes_requested')
assert_eq "PR #42 approved count" "1" "$pr42_approved"
assert_eq "PR #43 changes_requested count" "1" "$pr43_changes"

echo ""

# --- Test 10: CI summaries ---
echo "Test 10: CI summaries"
pr42_ci_passed=$(echo "$output" | jq '.sections.all_prs[] | select(.id == 42) | .ci.passed')
pr42_ci_total=$(echo "$output" | jq '.sections.all_prs[] | select(.id == 42) | .ci.total')
pr43_ci_failed=$(echo "$output" | jq '.sections.all_prs[] | select(.id == 43) | .ci.failed')
assert_eq "PR #42 CI passed" "3" "$pr42_ci_passed"
assert_eq "PR #42 CI total" "3" "$pr42_ci_total"
assert_eq "PR #43 CI failed" "1" "$pr43_ci_failed"

echo ""

# --- Test 11: Job buckets ---
echo "Test 11: Job buckets"
running_count=$(echo "$output" | jq '.sections.running | length')
completed_count=$(echo "$output" | jq '.sections.recently_completed | length')
assert_eq "running jobs" "1" "$running_count"
assert_eq "recently completed (success + failure)" "2" "$completed_count"

echo ""

# --- Test 12: Summary counts ---
echo "Test 12: Summary aggregation"
summary_open=$(echo "$output" | jq '.summary.open_prs')
summary_attention=$(echo "$output" | jq '.summary.needs_attention')
summary_running=$(echo "$output" | jq '.summary.running_jobs')
assert_eq "open PRs" "5" "$summary_open"
assert_gt "attention count" 0 "$summary_attention"
assert_eq "running jobs" "1" "$summary_running"

echo ""

# --- Test 13: My PRs ---
echo "Test 13: My PRs section"
my_prs=$(echo "$output" | jq '.sections.my_prs | length')
assert_eq "my PRs count (testuser authored)" "4" "$my_prs"

echo ""

# --- Test 14: Review queue ---
echo "Test 14: Review queue"
review_queue=$(echo "$output" | jq '.sections.review_queue | length')
assert_eq "review queue (requested for testuser)" "1" "$review_queue"
review_pr=$(echo "$output" | jq -r '.sections.review_queue[0].id')
assert_eq "review queue PR is #43" "43" "$review_pr"

echo ""

# --- Test 15: Repos list ---
echo "Test 15: Repos enumeration"
repos_count=$(echo "$output" | jq '.repos | length')
assert_eq "unique repos" "2" "$repos_count"

echo ""

# --- Test 16: Gitea Actions fixture fields (regression) ---
echo "Test 16: Actions fixture validation"
run_501=$(echo "$output" | jq '.sections.running[] | select(.id == 501)')
assert_eq "run 501 has workflow" "CI Pipeline" "$(echo "$run_501" | jq -r '.workflow')"
assert_eq "run 501 status" "running" "$(echo "$run_501" | jq -r '.status')"
assert_eq "run 501 branch" "feature/auth" "$(echo "$run_501" | jq -r '.branch')"
assert_eq "run 501 has event" "push" "$(echo "$run_501" | jq -r '.event')"
assert_neq "run 501 has url" "" "$(echo "$run_501" | jq -r '.url')"

echo ""

# --- Test 17: Current Gitea Actions lifecycle/status fields ---
echo "Test 17: Current Gitea Actions response shape"
current_runs='[
  {"id":601,"_repo":"testuser/webapp","display_title":"Build main","path":".gitea/workflows/build.yml","status":"completed","conclusion":"success","head_branch":"main","event":"push","started_at":"2026-09-15T11:00:00Z","completed_at":"2026-09-15T11:05:00Z","html_url":"https://git.example.com/run/601"},
  {"id":602,"_repo":"testuser/webapp","display_title":"Test main","path":".gitea/workflows/test.yml","status":"completed","conclusion":"failure","head_branch":"main","event":"push","started_at":"2026-09-15T11:06:00Z","completed_at":"2026-09-15T11:10:00Z","html_url":"https://git.example.com/run/602"},
  {"id":603,"_repo":"testuser/webapp","display_title":"Deploy main","path":".gitea/workflows/deploy.yml","status":"in_progress","conclusion":null,"head_branch":"main","event":"push","started_at":"2026-09-15T11:11:00Z","completed_at":null,"html_url":"https://git.example.com/run/603"}
]'
current_output=$(run_jq "[]" "$current_runs")
assert_eq "completed success is shown as completed" "completed" \
  "$(echo "$current_output" | jq -r '.sections.recently_completed[] | select(.id == 601) | .bucket')"
assert_eq "completed failure is shown as failed" "failed" \
  "$(echo "$current_output" | jq -r '.sections.recently_completed[] | select(.id == 602) | .bucket')"
assert_eq "in-progress run is shown as running" "running" \
  "$(echo "$current_output" | jq -r '.sections.running[] | select(.id == 603) | .bucket')"
assert_eq "display_title supplies workflow label" "Build main" \
  "$(echo "$current_output" | jq -r '.sections.recently_completed[] | select(.id == 601) | .workflow')"
assert_eq "completed_at supplies updated timestamp" "2026-09-15T11:05:00Z" \
  "$(echo "$current_output" | jq -r '.sections.recently_completed[] | select(.id == 601) | .updated')"

echo ""

# === Summary ===
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
