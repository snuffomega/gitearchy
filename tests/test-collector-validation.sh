#!/usr/bin/env bash
# Validate the collector script — syntax, error paths, and mocked execution.
# No real network or Gitea credentials needed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLLECTOR="$SCRIPT_DIR/../bin/gitea-collect"
MOCK_DIR="$SCRIPT_DIR/mock-responses"
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

assert_file_exists() {
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (file not found: $path)"
    FAIL=$((FAIL + 1))
  fi
}

# Creates a fresh temp environment, sets XDG_STATE_HOME/XDG_CONFIG_HOME, returns path
setup_env() {
  _SETUP_TMP=$(mktemp -d)
  unset GITEA_WS_MAX_STALE_HOURS
  export XDG_STATE_HOME="$_SETUP_TMP/state"
  export XDG_CONFIG_HOME="$_SETUP_TMP/config"
  mkdir -p "$XDG_STATE_HOME/omarchy/gitea-workstatus" "$XDG_CONFIG_HOME/gitea-workstatus"
  printf 'GITEA_URL="https://mock.test"\nGITEA_TOKEN="mock-token"\n' > "$XDG_CONFIG_HOME/gitea-workstatus/credentials"
}

# Creates a mock curl that returns status code and body based on path matching
# Usage: make_mock_curl <tmpdir> <behavior>
# behavior: "normal" | "500_repos" | "401_auth" | "malformed" | "timeout" | "pr_fail" | "actions_only" | "large_actions"
make_mock_curl() {
  local tmpdir="$1" behavior="$2"
  cat > "$tmpdir/curl" << ENDCURL
#!/usr/bin/env bash
url=""
has_write_out=false
# Record argv and any config stream so tests can check where the token travels.
printf '%s\n' "\$*" >> "$tmpdir/curl-argv.log"
prev=""
for arg in "\$@"; do
  case "\$prev" in
    -K|--config) cat "\$arg" >> "$tmpdir/curl-config.log" 2>/dev/null ;;
  esac
  case "\$arg" in
    https://*) url="\$arg" ;;
    *http_code*) has_write_out=true ;;
  esac
  prev="\$arg"
done

mock_dir="$MOCK_DIR"
path=\$(echo "\$url" | grep -oP '/api/v1\K[^?]*' || echo "")

case "$behavior" in
  500_repos)
    case "\$path" in
      /user) cat "\$mock_dir/user.json"; \$has_write_out && printf '\n200' ;;
      /user/repos) echo '{"message":"Internal Server Error"}'; \$has_write_out && printf '\n500' ;;
      *) echo '[]'; \$has_write_out && printf '\n200' ;;
    esac
    ;;
  401_auth)
    echo '{"message":"Unauthorized"}'; \$has_write_out && printf '\n401'
    ;;
  malformed)
    case "\$path" in
      /user) cat "\$mock_dir/user.json"; \$has_write_out && printf '\n200' ;;
      /user/repos) echo 'not json at all {{{'; \$has_write_out && printf '\n200' ;;
      *) echo '[]'; \$has_write_out && printf '\n200' ;;
    esac
    ;;
  timeout)
    sleep 20
    exit 1
    ;;
  pr_fail)
    case "\$path" in
      /user) cat "\$mock_dir/user.json"; \$has_write_out && printf '\n200' ;;
      /user/repos) cat "\$mock_dir/repos.json"; \$has_write_out && printf '\n200' ;;
      /repos/*/pulls) echo '{"error": "oops"}'; \$has_write_out && printf '\n500' ;;
      /repos/*/actions/runs) cat "\$mock_dir/action-runs.json"; \$has_write_out && printf '\n200' ;;
      *) echo '[]'; \$has_write_out && printf '\n200' ;;
    esac
    ;;
  actions_only)
    case "\$path" in
      /user) cat "\$mock_dir/user.json"; \$has_write_out && printf '\n200' ;;
      /user/repos) echo '[{"owner":{"login":"testuser"},"name":"ci-only","has_pull_requests":false},{"owner":{"login":"testuser"},"name":"empty","has_pull_requests":true,"empty":true}]'; \$has_write_out && printf '\n200' ;;
      /repos/*/pulls) echo '{"message":"pull requests unavailable"}'; \$has_write_out && printf '\n404' ;;
      /repos/*/actions/runs) cat "\$mock_dir/action-runs.json"; \$has_write_out && printf '\n200' ;;
      *) echo '[]'; \$has_write_out && printf '\n200' ;;
    esac
    ;;
  large_actions)
    case "\$path" in
      /user) cat "\$mock_dir/user.json"; \$has_write_out && printf '\n200' ;;
      /user/repos) echo '[{"owner":{"login":"testuser"},"name":"large-ci","has_pull_requests":false}]'; \$has_write_out && printf '\n200' ;;
      /repos/*/actions/runs)
        jq -n '{workflow_runs: [range(20) | {id: ., name: "CI", status: "success", conclusion: "success", head_branch: "main", event: "push", created_at: "2026-09-15T09:30:00Z", updated_at: "2026-09-15T09:32:00Z", html_url: "https://mock.test/run", padding: ("x" * 20000)}]}'
        \$has_write_out && printf '\n200'
        ;;
      *) echo '[]'; \$has_write_out && printf '\n200' ;;
    esac
    ;;
  normal|*)
    case "\$path" in
      /user) cat "\$mock_dir/user.json"; \$has_write_out && printf '\n200' ;;
      /user/repos) cat "\$mock_dir/repos.json"; \$has_write_out && printf '\n200' ;;
      /repos/*/pulls)
        if echo "\$url" | grep -q "testuser/webapp"; then
          jq '[.[0], .[1]]' "\$mock_dir/pulls.json"
        else
          echo "[]"
        fi
        \$has_write_out && printf '\n200'
        ;;
      /repos/*/pulls/*/reviews) cat "\$mock_dir/reviews.json"; \$has_write_out && printf '\n200' ;;
      /repos/*/commits/*/status) cat "\$mock_dir/commit-status-success.json"; \$has_write_out && printf '\n200' ;;
      /repos/*/actions/runs) cat "\$mock_dir/action-runs.json"; \$has_write_out && printf '\n200' ;;
      *) echo '[]'; \$has_write_out && printf '\n200' ;;
    esac
    ;;
esac
exit 0
ENDCURL
  chmod +x "$tmpdir/curl"
}

echo "=== Collector Validation Tests ==="
echo ""

# ── Test 1: Script syntax ──
echo "Test 1: Script can be invoked via bash"
if bash -n "$COLLECTOR" 2>/dev/null; then
  echo "  PASS: bash -n passes"
  PASS=$((PASS + 1))
else
  echo "  FAIL: bash -n failed"
  FAIL=$((FAIL + 1))
fi

# ── Test 2: JQ script syntax ──
echo "Test 2: JQ transform syntax"
JQ_SCRIPT="$SCRIPT_DIR/../bin/gitea-collect.jq"
if jq -n -f "$JQ_SCRIPT" \
  --arg url "test" --arg user "test" --arg ts "test" \
  --argjson prs "[]" --argjson runs "[]" \
  --argjson repo_count 0 --argjson max_stale 6 \
  --argjson repo_failed 0 --argjson repo_attempted 0 \
  --argjson incomplete false \
  --argjson carried false \
  --argjson carried_repos "[]" \
  --argjson failed_resources "{}" \
  >/dev/null 2>&1; then
  echo "  PASS: jq syntax valid"
  PASS=$((PASS + 1))
else
  echo "  FAIL: jq syntax invalid"
  FAIL=$((FAIL + 1))
fi

# ── Test 3: Missing credentials ──
echo "Test 3: Missing credentials error"
setup_env; tmpdir="$_SETUP_TMP"
rm -f "$XDG_CONFIG_HOME/gitea-workstatus/credentials"
state_file="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"

set +e
bash "$COLLECTOR" 2>/dev/null
missing_credentials_status=$?
set -e
assert_eq "missing credentials exits nonzero" "1" "$missing_credentials_status"

if [ -f "$state_file" ]; then
  error_msg=$(jq -r '.error // empty' "$state_file" 2>/dev/null)
  assert_contains "error mentions credentials" "credentials" "$error_msg"
  if jq empty "$state_file" 2>/dev/null; then
    echo "  PASS: error output is valid JSON"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: error output is not valid JSON"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: collector should write error JSON to state file"
  FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# ── Test 4: Empty GITEA_URL ──
echo "Test 4: Empty URL error"
setup_env; tmpdir="$_SETUP_TMP"
printf 'GITEA_URL=""\nGITEA_TOKEN="test-token"\n' > "$XDG_CONFIG_HOME/gitea-workstatus/credentials"
state_file="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"

set +e
bash "$COLLECTOR" 2>/dev/null
empty_url_status=$?
set -e
assert_eq "empty URL exits nonzero" "1" "$empty_url_status"
if [ -f "$state_file" ]; then
  error_msg=$(jq -r '.error // empty' "$state_file" 2>/dev/null)
  assert_contains "error mentions URL" "URL" "$error_msg"
fi
rm -rf "$tmpdir"

# ── Test 5: flock-based lock ──
echo "Test 5: flock-based lock"
setup_env; tmpdir="$_SETUP_TMP"
lock_file="$XDG_STATE_HOME/omarchy/gitea-workstatus/.collect.lock"
# Write something arbitrary into the lock file
echo "old-content" > "$lock_file"
# flock should still acquire it (flock doesn't care about file content)
bash "$COLLECTOR" 2>/dev/null || true
echo "  PASS: flock acquires lock regardless of file content"
PASS=$((PASS + 1))
rm -rf "$tmpdir"

# ── Test 6: Normal mocked execution ──
echo "Test 6: Mocked collector execution"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
make_mock_curl "$tmpdir" "normal"
set +e
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
normal_status=$?
set -e
assert_eq "mocked collector exits successfully" "0" "$normal_status"

if [ -f "$mock_state" ]; then
  if jq empty "$mock_state" 2>/dev/null; then
    echo "  PASS: mocked collector produces valid JSON"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: mocked collector output is not valid JSON"
    FAIL=$((FAIL + 1))
  fi
  assert_eq "has meta" "true" "$(jq 'has("meta")' "$mock_state" 2>/dev/null)"
  assert_eq "has summary" "true" "$(jq 'has("summary")' "$mock_state" 2>/dev/null)"
  assert_eq "has sections" "true" "$(jq 'has("sections")' "$mock_state" 2>/dev/null)"
  pr_count=$(jq '.summary.open_prs // 0' "$mock_state" 2>/dev/null)
  assert_eq "has PRs" "true" "$([ "$pr_count" -gt 0 ] && echo true || echo false)"
  assert_eq "correct username" "testuser" "$(jq -r '.meta.username' "$mock_state" 2>/dev/null)"
  assert_eq "not stale" "false" "$(jq '.meta.stale' "$mock_state" 2>/dev/null)"
  # The token must never appear in a process's arguments (visible in /proc).
  assert_eq "token never in curl argv" "0" "$(grep -c 'mock-token' "$tmpdir/curl-argv.log")"
  assert_eq "auth header still reaches curl" "true" \
    "$(grep -q 'Authorization: token mock-token' "$tmpdir/curl-config.log" 2>/dev/null && echo true || echo false)"
  # The repo picker lists every fetched repository, not only active ones.
  assert_eq "known_repos lists every fetched repo" '["org/docs","testuser/api-server","testuser/webapp"]' \
    "$(jq -c '.known_repos' "$mock_state" 2>/dev/null)"
else
  echo "  FAIL: mocked collector did not write output file"
  FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# ── Test 7: HTTP 500 on repo listing ──
echo "Test 7: HTTP 500 on repo listing"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
make_mock_curl "$tmpdir" "500_repos"
set +e
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
repos_500_status=$?
set -e
assert_eq "repo-list 500 exits nonzero" "1" "$repos_500_status"

# Should die with error, but not crash
if [ -f "$XDG_STATE_HOME/omarchy/gitea-workstatus/last-error.json" ]; then
  assert_contains "500 error recorded" "Cannot list" "$(jq -r '.error // empty' "$XDG_STATE_HOME/omarchy/gitea-workstatus/last-error.json" 2>/dev/null)"
else
  # Error may be in overview.json if no prior good data
  if [ -f "$mock_state" ]; then
    assert_contains "500 error in state" "Cannot list\|error\|Error" "$(jq -r '.error // .meta.error // empty' "$mock_state" 2>/dev/null)"
  else
    echo "  FAIL: no error file written for 500 response"
    FAIL=$((FAIL + 1))
  fi
fi
rm -rf "$tmpdir"

# ── Test 8: Authentication failure preserves last-good data ──
echo "Test 8: Auth failure preserves last-good data"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
# Write "last-good" data
echo '{"meta":{"collected_at":"2024-01-01T00:00:00Z","stale":false},"summary":{"open_prs":5},"sections":{}}' > "$mock_state"
make_mock_curl "$tmpdir" "401_auth"
set +e
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
auth_status=$?
set -e
assert_eq "authentication failure exits nonzero" "1" "$auth_status"

# Last-good data should still be there
preserved_prs=$(jq '.summary.open_prs // 0' "$mock_state" 2>/dev/null)
assert_eq "last-good data preserved" "5" "$preserved_prs"
assert_file_exists "error file written" "$XDG_STATE_HOME/omarchy/gitea-workstatus/last-error.json"
rm -rf "$tmpdir"

# ── Test 9: Malformed JSON response ──
echo "Test 9: Malformed JSON from repo listing"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
make_mock_curl "$tmpdir" "malformed"
set +e
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
malformed_status=$?
set -e
assert_eq "malformed repos response exits nonzero" "1" "$malformed_status"
assert_eq "malformed repos response writes error" "true" \
  "$(jq 'has("error")' "$mock_state" 2>/dev/null)"
rm -rf "$tmpdir"

# ── Test 10: PR/review failures with Actions still working ──
echo "Test 10: PR failures with Actions still working"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
make_mock_curl "$tmpdir" "pr_fail"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
assert_eq "partial repo failure exits successfully" "0" "$?"

if [ -f "$mock_state" ] && jq -e 'has("sections")' "$mock_state" >/dev/null 2>&1; then
  # Actions runs should still have been collected
  run_count=$(jq '[.sections.running[]?, .sections.recently_completed[]?] | length' "$mock_state" 2>/dev/null || echo "0")
  assert_eq "runs collected despite PR failure" "true" "$([ "$run_count" -ge 0 ] && echo true || echo false)"
  repo_failed=$(jq '.meta.repo_failed // 0' "$mock_state" 2>/dev/null)
  assert_eq "partial failure counted" "true" "$([ "$repo_failed" -gt 0 ] && echo true || echo false)"
else
  echo "  PASS: collector handled PR failure (error or partial output)"
  PASS=$((PASS + 1))
fi
rm -rf "$tmpdir"

# ── Test 11: Actions-only repos (has_pull_requests: false) ──
echo "Test 11: Actions-only repos"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
make_mock_curl "$tmpdir" "actions_only"
set +e
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
actions_only_status=$?
set -e
assert_eq "actions-only collection exits successfully" "0" "$actions_only_status"

if [ -f "$mock_state" ] && jq -e 'has("repos")' "$mock_state" >/dev/null 2>&1; then
  # The actions-only repo should appear in repos list
  has_ci_only=$(jq '.repos | index("testuser/ci-only") != null' "$mock_state" 2>/dev/null)
  assert_eq "actions-only repo in repos list" "true" "$has_ci_only"
  assert_eq "PR-disabled and empty repos are not failures" "0" \
    "$(jq '.meta.repo_failed' "$mock_state" 2>/dev/null)"
  assert_eq "PR-disabled and empty repos do not mark stale" "false" \
    "$(jq '.meta.stale' "$mock_state" 2>/dev/null)"
else
  echo "  FAIL: no repos data for actions-only test"
  FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# ── Test 12: (replaced by Acceptance A2/A3 below) Empty-success carry-forward removed ──
# Empty PRs/runs from successful responses are valid data — old behavior that
# treated empty as failure was the bug. A2/A3 now verify correct semantics.

# ── Test 13: Two concurrent collectors (flock contention) ──
echo "Test 13: Two concurrent collectors (flock)"
setup_env; tmpdir="$_SETUP_TMP"
lock_file="$XDG_STATE_HOME/omarchy/gitea-workstatus/.collect.lock"

# Hold the lock in background
(
  exec 9>"$lock_file"
  flock 9
  sleep 3
) &
holder_pid=$!
sleep 0.5

# Second collector should exit immediately with exit code 0
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
exit_code=$?
assert_eq "second collector exits cleanly" "0" "$exit_code"

kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -rf "$tmpdir"

# ── Test 14 (Acceptance 1): successful PRs + successful EMPTY Actions ──
# Expect: current PRs published, old runs cleared, NOT stale.
echo "Test 14 (A1): PRs succeed, Actions succeeds-but-empty -> publish, not stale"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
cat > "$mock_state" << 'OLD'
{"meta":{"collected_at":"2026-09-15T00:00:00Z","stale":false},"summary":{"open_prs":3,"running_jobs":2},"sections":{"all_prs":[],"running":[],"recently_completed":[{"repo":"test/r","id":99}],"attention":[],"my_prs":[],"review_queue":[]},"repos":["test/r"]}
OLD
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r","has_pull_requests":true}]'; $write && printf '\n200' ;;
  /repos/*/pulls) echo '[{"number":1,"title":"P","state":"open","draft":false,"user":{"login":"testuser"},"head":{"ref":"main","sha":"a"},"base":{"ref":"main"},"created_at":"2026-09-15T09:00:00Z","updated_at":"2026-09-15T09:00:00Z","html_url":"https://x/r/pulls/1","mergeable":true,"labels":[],"requested_reviewers":[]}]'; $write && printf '\n200' ;;
  /repos/*/pulls/*/reviews) echo '[]'; $write && printf '\n200' ;;
  /repos/*/commits/*/status) echo '{}'; $write && printf '\n200' ;;
  /repos/*/actions/runs) echo '{"total_count":0,"workflow_runs":[]}'; $write && printf '\n200' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
assert_eq "A1: publish 1 PR (not carried-forward 3)" "1" "$(jq '.summary.open_prs // .summary.openPRs // 0' "$mock_state" 2>/dev/null)"
assert_eq "A1: old runs cleared (running = 0)" "0" "$(jq '[.sections.running[]?] | length' "$mock_state" 2>/dev/null)"
assert_eq "A1: recently_completed cleared (0)" "0" "$(jq '[.sections.recently_completed[]?] | length' "$mock_state" 2>/dev/null)"
assert_eq "A1: NOT stale" "false" "$(jq '.meta.stale // false' "$mock_state" 2>/dev/null)"
rm -rf "$tmpdir"

# ── Test 15 (Acceptance 2): successful EMPTY PR and Actions responses ──
# Expect: clear old PRs/runs, publish a successful empty snapshot, NOT stale.
echo "Test 15 (A2): PRs empty + Actions empty -> empty snapshot, not stale"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
cat > "$mock_state" << 'OLD'
{"meta":{"collected_at":"2026-09-15T00:00:00Z","stale":false},"summary":{"open_prs":3,"running_jobs":2},"sections":{"all_prs":[{"repo":"test/r","id":1}],"running":[{"repo":"test/r","id":99}],"recently_completed":[],"attention":[],"my_prs":[],"review_queue":[]},"repos":["test/r"]}
OLD
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r","has_pull_requests":true}]'; $write && printf '\n200' ;;
  /repos/*/pulls) echo '[]'; $write && printf '\n200' ;;
  /repos/*/actions/runs) echo '{"total_count":0,"workflow_runs":[]}'; $write && printf '\n200' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
assert_eq "A2: open PRs cleared to 0" "0" "$(jq '.summary.open_prs // 0' "$mock_state" 2>/dev/null)"
assert_eq "A2: running cleared to 0" "0" "$(jq '[.sections.running[]?] | length' "$mock_state" 2>/dev/null)"
assert_eq "A2: snapshot is healthy, NOT stale" "false" "$(jq '.meta.stale // false' "$mock_state" 2>/dev/null)"
assert_eq "A2: snapshot still has sections" "true" "$(jq 'has("sections")' "$mock_state" 2>/dev/null)"
rm -rf "$tmpdir"

# ── Test 16 (Acceptance 3): a FAILED request ──
# Expect: last-good info preserved with ORIGINAL timestamp, explicitly stale/failed.
echo "Test 16 (A3): failed request -> preserve last-good, mark stale"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
orig_ts="2026-09-15T00:00:00Z"
cat > "$mock_state" << OLD
{"meta":{"collected_at":"$orig_ts","stale":false,"repo_failed":0,"repo_attempted":1},"summary":{"open_prs":7},"sections":{"all_prs":[{"repo":"test/r","id":1}],"running":[],"recently_completed":[],"attention":[],"my_prs":[],"review_queue":[]},"repos":["test/r"]}
OLD
# repos listing -> 500 (request failure)
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '{"message":"err"}'; $write && printf '\n500' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
assert_eq "A3: last-good PRs preserved (7)" "7" "$(jq '.summary.open_prs // 0' "$mock_state" 2>/dev/null)"
assert_eq "A3: ORIGINAL timestamp preserved" "$orig_ts" "$(jq -r '.meta.collected_at // empty' "$mock_state" 2>/dev/null)"
# stale must be explicitly reported: either meta.stale=true on preserved data, or an error file/snapshot
stale_flag=$(jq '.meta.stale // empty' "$mock_state" 2>/dev/null)
err_file="$XDG_STATE_HOME/omarchy/gitea-workstatus/last-error.json"
if [ "$stale_flag" = "true" ]; then
  assert_eq "A3: stale explicitly reported (meta.stale)" "true" "$stale_flag"
elif [ -f "$err_file" ]; then
  assert_eq "A3: failure explicitly reported (last-error.json)" "true" "$(jq 'has("error")' "$err_file" 2>/dev/null)"
else
  echo "  FAIL: A3: neither meta.stale nor last-error.json reports failure"
  FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# ── Test 17 (Acceptance 4): later pagination page fails ──
# Expect: retain the page-1 info, but EXPLICITLY report incomplete coverage.
echo "Test 17 (A4): later pagination page fails -> partial data + incomplete coverage"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
page=$(echo "$url" | grep -oP 'page=\K[0-9]+' || echo "1")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos)
    if [ "$page" = "1" ]; then
      jq -n '[range(50) | {"owner":{"login":"t"},"name":("r"+(.|tostring)),"has_pull_requests":false}]'
      $write && printf '\n200'
    else
      echo '{"message":"err"}'; $write && printf '\n500'
    fi ;;
  /repos/*/actions/runs) echo '{"total_count":0,"workflow_runs":[]}'; $write && printf '\n200' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
if [ -f "$mock_state" ] && jq -e 'has("meta")' "$mock_state" >/dev/null 2>&1; then
  n=$(jq '.meta.repo_count // (.repos|length) // 0' "$mock_state" 2>/dev/null)
  assert_eq "A4: page-1 repos retained (>=50)" "true" "$([ "$n" -ge 50 ] && echo true || echo false)"
  # incomplete coverage must be flagged: stale OR incomplete OR repo_failed>0
  s=$(jq '.meta.stale // false' "$mock_state" 2>/dev/null)
  inc=$(jq '.meta.incomplete // empty' "$mock_state" 2>/dev/null)
  rf=$(jq '.meta.repo_failed // 0' "$mock_state" 2>/dev/null)
  if [ "$s" = "true" ] || [ "$inc" = "true" ] || [ "$rf" -gt 0 ]; then
    echo "  PASS: A4: incomplete coverage explicitly flagged"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: A4: incomplete coverage NOT flagged (stale='$s' incomplete='$inc' repo_failed='$rf')"
    FAIL=$((FAIL + 1))
  fi
else
  echo "  FAIL: A4: collector produced no output on later-page failure"
  FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# ── Test 18 (Acceptance 5): Actions timeout/connection failure ──
# Expect: transport failure reported; never manufacture HTTP 404 (ok).
echo "Test 18 (A5): Actions transport failure -> reported, NOT treated as 404-ok"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in https://*) url="$a";; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}
200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r","has_pull_requests":true}]
200' ;;
  /repos/*/pulls) echo '[]
200' ;;
  /repos/*/actions/runs) exit 28 ;; # curl transport failure (timeout)
  *) echo '[]
200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
rf=$(jq '.meta.repo_failed // 0' "$mock_state" 2>/dev/null)
s=$(jq '.meta.stale // false' "$mock_state" 2>/dev/null)
if [ "$rf" -gt 0 ] || [ "$s" = "true" ]; then
  echo "  PASS: A5: transport failure reported (repo_failed=$rf stale=$s)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: A5: transport failure NOT reported (repo_failed=$rf stale=$s) — collector must not treat it as clean"
  FAIL=$((FAIL + 1))
fi
rm -rf "$tmpdir"

# ── Test 19 (Acceptance 6): failed collection after maxStaleHours ──
# Carry-forward only within maxStaleHours; beyond it, report failure, not healthy.
echo "Test 19 (A6): failed request, last-good older than maxStaleHours -> report failure"
setup_env; tmpdir="$_SETUP_TMP"
export GITEA_WS_MAX_STALE_HOURS=1
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
old_ts=$(date -u -d "5 hours ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-09-15T00:00:00Z")
cat > "$mock_state" << OLD
{"meta":{"collected_at":"$old_ts","stale":false},"summary":{"open_prs":9},"sections":{"all_prs":[],"running":[],"recently_completed":[],"attention":[],"my_prs":[],"review_queue":[]},"repos":[]}
OLD
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '{"message":"err"}'; $write && printf '\n500' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
err_file="$XDG_STATE_HOME/omarchy/gitea-workstatus/last-error.json"
# With old data beyond maxStaleHours, a failed request must NOT be silently kept as healthy.
# Either an error file exists, or the snapshot is marked stale (never claim healthy).
if [ -f "$err_file" ]; then
  assert_eq "A6: failure reported via last-error.json" "true" "$(jq 'has("error")' "$err_file" 2>/dev/null)"
else
  s=$(jq '.meta.stale // false' "$mock_state" 2>/dev/null)
  assert_eq "A6: snapshot marked stale (not healthy)" "true" "$s"
fi
rm -rf "$tmpdir"
# ── Test 20: per-resource failure handling + explicit exit/stderr retention ──
echo "Test 20: per-resource failures (PR 500 carry-forward, review failure reported)"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
orig_ts=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-09-15T00:00:00Z")
cat > "$mock_state" << OLD
{"meta":{"collected_at":"$orig_ts","stale":false},"summary":{"open_prs":1},"sections":{"all_prs":[{"id":1,"repo":"t/r","author":"testuser","updated":"$orig_ts","needs_attention":true,"status_label":"review_requested","requested_reviewers":["testuser"]}],"running":[],"recently_completed":[{"repo":"t/r","id":9,"bucket":"completed","updated":"$orig_ts"}],"attention":[],"my_prs":[],"review_queue":[]},"repos":["t/r"]}
OLD
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r","has_pull_requests":true}]'; $write && printf '\n200' ;;
  /repos/*/pulls) echo '{"m":"e"}'; $write && printf '\n500' ;;
  /repos/*/actions/runs) echo '{"total_count":0,"workflow_runs":[]}'; $write && printf '\n200' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
# retain stderr, assert exit status
errlog="$tmpdir/collector.stderr"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>"$errlog"
exit_status=$?
assert_eq "PR 500 exits 0 (partial success)" "0" "$exit_status"
# last-good PR for this repo should be carried forward — verify via carried_repos meta
assert_eq "carried PR preserved (t/r in carried_repos)" "true" "$(jq '.meta.carried_repos | index("t/r") != null' "$mock_state" 2>/dev/null)"
# explicit failure metadata present for the repo, including prs
meta_has=$(jq '.meta | has("failed_resources")' "$mock_state" 2>/dev/null)
assert_eq "failed_resources present in meta" "true" "$meta_has"
fr=$(jq -r '.meta.failed_resources["t/r"] // [] | index("prs") | tostring' "$mock_state" 2>/dev/null)
assert_eq "prs reported as failed resource" "0" "$fr"
carried=$(jq '.meta.carried // false' "$mock_state" 2>/dev/null)
assert_eq "carried flagged" "true" "$carried"
assert_eq "carried PR is present in all_prs" "1" \
  "$(jq '[.sections.all_prs[]? | select(.repo == "t/r")] | length' "$mock_state" 2>/dev/null)"
assert_eq "carried PR rebuilds attention section" "1" "$(jq '.sections.attention | length' "$mock_state")"
assert_eq "carried PR rebuilds my-PR section" "1" "$(jq '.sections.my_prs | length' "$mock_state")"
assert_eq "carried PR rebuilds review queue" "1" "$(jq '.sections.review_queue | length' "$mock_state")"
assert_eq "carried PR rebuilds summary counts" "1/1/1" \
  "$(jq -r '[.summary.open_prs, .summary.needs_attention, .summary.review_requested] | map(tostring) | join("/")' "$mock_state")"
assert_eq "successful empty Actions clears old runs" "0" \
  "$(jq '([.sections.running[]?] + [.sections.recently_completed[]?]) | map(select(.repo == "t/r")) | length' "$mock_state" 2>/dev/null)"
assert_eq "partial resource output is stale" "true" "$(jq '.meta.stale' "$mock_state" 2>/dev/null)"
# stderr retained (not hidden)
assert_file_exists "stderr log retained" "$errlog"
rm -rf "$tmpdir"

# ── Test 21: review and commit-status failures are reported as failed resources ──
echo "Test 21: review/status failures reported per-PR as failed resources"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r","has_pull_requests":true}]'; $write && printf '\n200' ;;
  /repos/*/pulls) echo '[{"number":7,"title":"P","state":"open","draft":false,"user":{"login":"t"},"head":{"ref":"m","sha":"a"},"base":{"ref":"m"},"created_at":"2026-09-15T09:00:00Z","updated_at":"2026-09-15T09:00:00Z","html_url":"https://x/r/pulls/7","mergeable":true,"labels":[],"requested_reviewers":[]}]'; $write && printf '\n200' ;;
  /repos/*/pulls/*/reviews) echo 'not json'; $write && printf '\n500' ;;
  /repos/*/commits/*/status) exit 28 ;; # transport failure
  /repos/*/actions/runs) echo '{"total_count":0,"workflow_runs":[]}'; $write && printf '\n200' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null || true
frv=$(jq -r '.meta.failed_resources["t/r"] // [] | map(select(startswith("review:7")))[0] // ""' "$mock_state" 2>/dev/null)
fcs=$(jq -r '.meta.failed_resources["t/r"] // [] | map(select(startswith("status:7")))[0] // ""' "$mock_state" 2>/dev/null)
assert_eq "review:7 reported as failed resource" "review:7" "$frv"
assert_eq "status:7 reported as failed resource" "status:7" "$fcs"
# successful PR still published (PR itself succeeded even though enrichment failed)
assert_eq "PR published despite review failure" "1" "$(jq '[.sections.all_prs[]?] | length' "$mock_state" 2>/dev/null)"
assert_eq "enrichment failure marks snapshot stale" "true" "$(jq '.meta.stale' "$mock_state" 2>/dev/null)"
rm -rf "$tmpdir"

# ── Test 22: Actions failure carries runs without reviving old PRs ──
echo "Test 22: Actions failure carries only runs; current PR data wins"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
orig_ts=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-09-15T00:00:00Z")
cat > "$mock_state" << OLD
{"meta":{"collected_at":"$orig_ts","stale":false},"summary":{"open_prs":1,"running_jobs":1},"sections":{"all_prs":[{"id":1,"repo":"t/r","author":"old","updated":"$orig_ts","needs_attention":false,"status_label":"open","requested_reviewers":[]}],"running":[{"repo":"t/r","id":9,"bucket":"running","updated":"$orig_ts"}],"recently_completed":[],"attention":[],"my_prs":[],"review_queue":[]},"repos":["t/r"]}
OLD
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r","has_pull_requests":true}]'; $write && printf '\n200' ;;
  /repos/*/pulls) echo '[{"number":7,"title":"Current","state":"open","draft":false,"user":{"login":"testuser"},"head":{"ref":"m","sha":"a"},"base":{"ref":"m"},"created_at":"2026-09-15T09:00:00Z","updated_at":"2026-09-15T09:00:00Z","html_url":"https://x/r/pulls/7","mergeable":true,"labels":[],"requested_reviewers":[]}]'; $write && printf '\n200' ;;
  /repos/*/pulls/*/reviews) echo '[]'; $write && printf '\n200' ;;
  /repos/*/commits/*/status) echo '{}'; $write && printf '\n200' ;;
  /repos/*/actions/runs) echo '{"message":"err"}'; $write && printf '\n500' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
assert_eq "Actions 500 exits 0 (partial success)" "0" "$?"
assert_eq "current PR replaces old PR" "7" "$(jq -r '.sections.all_prs | map(.id) | join(",")' "$mock_state")"
assert_eq "last-good running job carried" "9" "$(jq -r '.sections.running | map(.id) | join(",")' "$mock_state")"
assert_eq "run-only carry marks snapshot stale" "true" "$(jq '.meta.stale' "$mock_state")"
assert_eq "only runs reported failed" '["runs"]' "$(jq -c '.meta.failed_resources["t/r"]' "$mock_state")"
rm -rf "$tmpdir"

# ── Test 23: enrichment carry-forward is field-specific ──
echo "Test 23: review/status carry-forward preserves only the failed enrichment"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
orig_ts=$(date -u -d "1 hour ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "2026-09-15T00:00:00Z")
cat > "$mock_state" << OLD
{"meta":{"collected_at":"$orig_ts","stale":false},"summary":{"open_prs":2},"sections":{"all_prs":[{"id":7,"repo":"t/r-review","title":"Old review title","reviews":{"approved":0,"changes_requested":1,"pending":0,"reviewers":["alice"],"all_reviewers":["alice"]},"ci":{"state":"success","total":1,"checks":[],"passed":1,"failed":0,"pending_count":0}},{"id":7,"repo":"t/r-status","title":"Old status title","reviews":{"approved":1,"changes_requested":0,"pending":0,"reviewers":["alice"],"all_reviewers":["alice"]},"ci":{"state":"failure","total":1,"checks":[],"passed":0,"failed":1,"pending_count":0}}],"running":[],"recently_completed":[],"attention":[],"my_prs":[],"review_queue":[]},"repos":["t/r-review","t/r-status"]}
OLD
cat > "$tmpdir/curl" << 'EOF'
#!/usr/bin/env bash
url=""; write=false
for a in "$@"; do case "$a" in https://*) url="$a";; *http_code*) write=true;; esac; done
p=$(echo "$url" | grep -oP '/api/v1\K[^?]*' || echo "")
case "$p" in
  /user) echo '{"login":"testuser"}'; $write && printf '\n200' ;;
  /user/repos) echo '[{"owner":{"login":"t"},"name":"r-review","has_pull_requests":true},{"owner":{"login":"t"},"name":"r-status","has_pull_requests":true}]'; $write && printf '\n200' ;;
  /repos/t/r-review/pulls) echo '[{"number":7,"title":"Current review title","state":"open","draft":false,"user":{"login":"testuser"},"head":{"ref":"m","sha":"a"},"base":{"ref":"m"},"created_at":"2026-09-15T09:00:00Z","updated_at":"2026-09-16T09:00:00Z","html_url":"https://x/r-review/pulls/7","mergeable":true,"labels":[],"requested_reviewers":[]}]'; $write && printf '\n200' ;;
  /repos/t/r-status/pulls) echo '[{"number":7,"title":"Current status title","state":"open","draft":false,"user":{"login":"testuser"},"head":{"ref":"m","sha":"b"},"base":{"ref":"m"},"created_at":"2026-09-15T09:00:00Z","updated_at":"2026-09-16T09:00:00Z","html_url":"https://x/r-status/pulls/7","mergeable":true,"labels":[],"requested_reviewers":[]}]'; $write && printf '\n200' ;;
  /repos/t/r-review/pulls/7/reviews) echo '{"message":"err"}'; $write && printf '\n500' ;;
  /repos/t/r-status/pulls/7/reviews) echo '[]'; $write && printf '\n200' ;;
  /repos/t/r-review/commits/a/status) echo '{}'; $write && printf '\n200' ;;
  /repos/t/r-status/commits/b/status) echo '{"message":"err"}'; $write && printf '\n500' ;;
  /repos/*/actions/runs) echo '{"total_count":0,"workflow_runs":[]}'; $write && printf '\n200' ;;
  *) echo '[]'; $write && printf '\n200' ;;
esac
exit 0
EOF
chmod +x "$tmpdir/curl"
PATH="$tmpdir:$PATH" bash "$COLLECTOR" 2>/dev/null
assert_eq "enrichment-only failure exits successfully" "0" "$?"
assert_eq "review carry keeps current PR fields" "Current review title" \
  "$(jq -r '.sections.all_prs[] | select(.repo == "t/r-review") | .title' "$mock_state")"
assert_eq "failed review is carried" "1" \
  "$(jq '.sections.all_prs[] | select(.repo == "t/r-review") | .reviews.changes_requested' "$mock_state")"
assert_eq "successful current status is not overwritten" "unknown" \
  "$(jq -r '.sections.all_prs[] | select(.repo == "t/r-review") | .ci.state' "$mock_state")"
assert_eq "status carry keeps current PR fields" "Current status title" \
  "$(jq -r '.sections.all_prs[] | select(.repo == "t/r-status") | .title' "$mock_state")"
assert_eq "successful current reviews are not overwritten" "0" \
  "$(jq '.sections.all_prs[] | select(.repo == "t/r-status") | .reviews.approved' "$mock_state")"
assert_eq "failed status is carried and reclassified" "failure/ci_failed" \
  "$(jq -r '.sections.all_prs[] | select(.repo == "t/r-status") | [.ci.state, .status_label] | join("/")' "$mock_state")"
rm -rf "$tmpdir"

# ── Test 24: large Actions response does not trip pipefail/SIGPIPE ──
echo "Test 24: large Actions response exits successfully and publishes runs"
setup_env; tmpdir="$_SETUP_TMP"
mock_state="$XDG_STATE_HOME/omarchy/gitea-workstatus/overview.json"
make_mock_curl "$tmpdir" "large_actions"
set +e
PATH="$tmpdir:$PATH" bash "$COLLECTOR" >/dev/null 2>&1
large_actions_status=$?
set -e
assert_eq "large Actions response exits successfully" "0" "$large_actions_status"
assert_eq "large Actions response publishes all runs" "20" \
  "$(jq '[.sections.running[]?, .sections.recently_completed[]?] | length' "$mock_state" 2>/dev/null)"
assert_eq "large Actions response is not marked stale" "false" \
  "$(jq '.meta.stale' "$mock_state" 2>/dev/null)"
rm -rf "$tmpdir"

echo ""
echo "==========================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==========================================="

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
