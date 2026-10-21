#!/usr/bin/env bash
# Test Model.js logic via Node.js — no QML runtime needed
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MOCK_DIR="$SCRIPT_DIR/mock-responses"
JQ_SCRIPT="$SCRIPT_DIR/../bin/gitea-collect.jq"

# Generate the overview JSON using the jq transform
build_test_prs() {
  local prs reviews_approved reviews_changes status_ok status_fail
  prs=$(cat "$MOCK_DIR/pulls.json")
  reviews_approved=$(cat "$MOCK_DIR/reviews.json")
  reviews_changes=$(cat "$MOCK_DIR/reviews-changes.json")
  status_ok=$(cat "$MOCK_DIR/commit-status-success.json")
  status_fail=$(cat "$MOCK_DIR/commit-status-failure.json")

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

test_prs=$(build_test_prs)
test_runs=$(build_test_runs)

overview=$(url="https://git.example.com" user="testuser" \
  carried_repos='[]' failed_resources='{}' jq -n \
  --arg ts "2026-09-15T10:00:00Z" \
  --argjson prs "$test_prs" \
  --argjson runs "$test_runs" \
  --argjson repo_count 3 \
  --argjson max_stale 6 \
  --argjson repo_failed 0 \
  --argjson repo_attempted 3 \
  --argjson incomplete false \
  --argjson carried false \
  -f "$JQ_SCRIPT")

overview_json=$(echo "$overview" | jq -c .)

# Build a second overview where PR #43's CI is now fixed (for notification transition test)
overview2_prs=$(echo "$test_prs" | jq \
  --argjson ci_ok "$(cat "$MOCK_DIR/commit-status-success.json")" \
  '.[1]._commit_status = $ci_ok')
overview2=$(url="https://git.example.com" user="testuser" \
  carried_repos='[]' failed_resources='{}' jq -n \
  --arg ts "2026-09-15T10:05:00Z" \
  --argjson prs "$overview2_prs" \
  --argjson runs "$test_runs" \
  --argjson repo_count 3 \
  --argjson max_stale 6 \
  --argjson repo_failed 0 \
  --argjson repo_attempted 3 \
  --argjson incomplete false \
  --argjson carried false \
  -f "$JQ_SCRIPT")
overview2_json=$(echo "$overview2" | jq -c .)

# Build a third overview where a NEW PR (#99) has CI failure (total count = 1 again)
overview3_prs=$(echo "$overview2_prs" | jq '. + [{
  "number": 99, "title": "New <b>broken</b> PR & co", "state": "open", "draft": false,
  "user": {"login": "someone"}, "head": {"ref": "broken", "sha": "zzz"},
  "base": {"ref": "main"}, "created_at": "2026-09-15T10:06:00Z",
  "updated_at": "2026-09-15T10:06:00Z", "html_url": "https://git.example.com/testuser/webapp/pulls/99",
  "mergeable": true, "labels": [], "requested_reviewers": [],
  "_reviews": [{"id": 99, "user": {"login": "x"}, "state": "REQUEST_CHANGES", "submitted_at": "2026-09-15T10:06:00Z"}],
  "_commit_status": {"state": "failure", "total_count": 1, "statuses": [{"context": "ci/build", "status": "failure", "description": "Build failed", "target_url": "", "created_at": "2026-09-15T10:06:00Z"}]},
  "_repo": "testuser/webapp"
}]')
overview3=$(url="https://git.example.com" user="testuser" \
  carried_repos='[]' failed_resources='{}' jq -n \
  --arg ts "2026-09-15T10:10:00Z" \
  --argjson prs "$overview3_prs" \
  --argjson runs "$test_runs" \
  --argjson repo_count 3 \
  --argjson max_stale 6 \
  --argjson repo_failed 0 \
  --argjson repo_attempted 3 \
  --argjson incomplete false \
  --argjson carried false \
  -f "$JQ_SCRIPT")
overview3_json=$(echo "$overview3" | jq -c .)

# Build a fourth overview whose runs use the current Actions lifecycle shape
# (status "completed", result in conclusion) alongside the legacy shape
overview4_runs=$(echo "$test_runs" | jq '. + [
  {"id": 600, "name": "release", "status": "completed", "conclusion": "failure",
   "head_branch": "main", "event": "push", "html_url": "https://git.example.com/testuser/webapp/actions/runs/600",
   "run_started_at": "2026-09-15T10:07:00Z", "updated_at": "2026-09-15T10:08:00Z", "_repo": "testuser/webapp"},
  {"id": 601, "name": "lint", "status": "completed", "conclusion": "cancelled",
   "head_branch": "main", "event": "push", "html_url": "https://git.example.com/testuser/webapp/actions/runs/601",
   "run_started_at": "2026-09-15T10:07:00Z", "updated_at": "2026-09-15T10:08:00Z", "_repo": "testuser/webapp"},
  {"id": 602, "name": "test", "status": "completed", "conclusion": "success",
   "head_branch": "main", "event": "push", "html_url": "https://git.example.com/testuser/webapp/actions/runs/602",
   "run_started_at": "2026-09-15T10:07:00Z", "updated_at": "2026-09-15T10:08:00Z", "_repo": "testuser/webapp"}
]')
overview4=$(url="https://git.example.com" user="testuser" \
  carried_repos='[]' failed_resources='{}' jq -n \
  --arg ts "2026-09-15T10:12:00Z" \
  --argjson prs "$test_prs" \
  --argjson runs "$overview4_runs" \
  --argjson repo_count 3 \
  --argjson max_stale 6 \
  --argjson repo_failed 0 \
  --argjson repo_attempted 3 \
  --argjson incomplete false \
  --argjson carried false \
  -f "$JQ_SCRIPT")
overview4_json=$(echo "$overview4" | jq -c .)

node <<NODETEST
const fs = require('fs');

const modelSrc = fs.readFileSync('$SCRIPT_DIR/../Model.js', 'utf-8')
  .replace('.pragma library', '');
eval(modelSrc);

let pass = 0, fail = 0;

function assert(desc, expected, actual) {
  if (expected === actual) { console.log("  PASS: " + desc); pass++; }
  else { console.log("  FAIL: " + desc + " (expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual) + ")"); fail++; }
}

console.log("=== Model.js Unit Tests ===");
console.log("");

// --- Test: parseOverview ---
console.log("Test: parseOverview");
let data = parseOverview(JSON.stringify($overview_json));
const giteaUrl = () => getMeta(data).gitea_url;
assert("parseOverview succeeds", true, data !== null && typeof data === "object");
assert("parseOverview rejects garbage", null, parseOverview("{nope"));
assert("failed parse leaves the last good snapshot intact", true, getMeta(data) !== null && getMeta(data).username === "testuser");

console.log("");
console.log("Test: getBarSummary (nothing hidden)");
const bar = getBarSummary(data, {});
assert("bar.total", 5, bar.total);
assert("bar.attention > 0", true, bar.attention > 0);
assert("bar.running", 1, bar.running);
assert("bar.healthy is false", false, bar.healthy);

console.log("");
console.log("Test: Section items");
const all = { hidden: {}, focus: "" };
assert("attention has items", true, sectionItems(data, "attention", all).length > 0);
assert("my_prs count", 4, sectionItems(data, "my_prs", all).length);
assert("unknown section falls back to attention", sectionItems(data, "attention", all).length, sectionItems(data, "bogus", all).length);

console.log("");
console.log("Test: Repo focus is per call, not remembered");
const focused = sectionItems(data, "all", { hidden: {}, focus: "testuser/webapp" });
assert("focused to webapp", true, focused.every(p => p.repo === "testuser/webapp"));
assert("focused count", 4, focused.length);
assert("next call without focus sees everything", 5, sectionItems(data, "all", all).length);

console.log("");
console.log("Test: repoSet");
assert("csv parsed", true, repoSet(" a/b, c/d ,")["c/d"] === true);
assert("array parsed", true, repoSet(["a/b"])["a/b"] === true);
assert("empty is empty", 0, Object.keys(repoSet("")).length);

console.log("");
console.log("Test: Hidden repos leave the bar, sections, and chips");
const hidden = repoSet("testuser/api-server");
assert("hidden repo excluded from bar total", 4, getBarSummary(data, hidden).total);
assert("hidden repo excluded from sections", true,
  sectionItems(data, "all", { hidden: hidden, focus: "" }).every(p => p.repo !== "testuser/api-server"));
assert("hidden repo excluded from chips", false, visibleRepos(data, hidden).indexOf("testuser/api-server") !== -1);
assert("visible repo kept in chips", true, visibleRepos(data, hidden).indexOf("testuser/webapp") !== -1);

console.log("");
console.log("Test: Repo picker rows");
data = parseOverview(JSON.stringify(Object.assign({}, $overview_json, { known_repos: ["org/docs", "testuser/api-server", "testuser/webapp"] })));
const known = knownRepos(data);
assert("known repos include inactive org/docs", true, known.indexOf("org/docs") !== -1);
assert("known repos sorted", "org/docs,testuser/api-server,testuser/webapp", known.join(","));
const rows = pickerRows(data, repoSet("org/docs"), "");
assert("picker lists every known repo", 3, rows.length);
assert("hidden repo is unchecked", false, rows.find(r => r.repo === "org/docs").shown);
assert("visible repo is checked", true, rows.find(r => r.repo === "testuser/webapp").shown);
assert("active repo is marked", true, rows.find(r => r.repo === "testuser/webapp").active);
assert("inactive repo is not marked", false, rows.find(r => r.repo === "org/docs").active);
assert("search is case-insensitive substring", "testuser/api-server", pickerRows(data, {}, "API").map(r => r.repo).join(","));
data = parseOverview(JSON.stringify($overview_json));
assert("older snapshot without known_repos falls back to active repos",
  visibleRepos(data, {}).slice().sort().join(","), knownRepos(data).join(","));

console.log("");
console.log("Test: Updating the hidden list");
assert("hide one", "a/b", updateHidden({}, ["a/b"], true).join(","));
assert("show one", "", updateHidden(repoSet("a/b"), ["a/b"], false).join(","));
assert("hide several, sorted, no dupes", "a/b,c/d", updateHidden(repoSet("c/d"), ["c/d", "a/b"], true).join(","));
assert("show several keeps others", "x/y", updateHidden(repoSet("a/b,x/y"), ["a/b"], false).join(","));
assert("hiddenSet unions list and legacy csv", "a/b,c/d", Object.keys(hiddenSet(["a/b"], "c/d")).sort().join(","));

console.log("");
console.log("Test: Cold-start notification suppression");
resetNotifications();
const notesCold = getNewNotifications(data, true, true);
assert("cold start: zero notifications", 0, notesCold.length);

console.log("");
console.log("Test: Notifications do NOT repeat for same state (post cold-start)");
const notes1b = getNewNotifications(data, true, true);
assert("repeat: no duplicate CI notification", 0, notes1b.filter(n => n.type === "failure").length);
assert("repeat: no duplicate review notification", 0, notes1b.filter(n => n.type === "review").length);

console.log("");
console.log("Test: Notification on transition (PR fixes, new PR breaks)");
data = parseOverview(JSON.stringify($overview2_json));
const notes2 = getNewNotifications(data, true, true);
assert("transition: no CI notification for fixed PR", 0, notes2.filter(n => n.type === "failure").length);

data = parseOverview(JSON.stringify($overview3_json));
const notes3 = getNewNotifications(data, true, true);
const newFailNotes = notes3.filter(n => n.type === "failure");
assert("new PR failure: fires notification", true, newFailNotes.length > 0);
assert("new PR failure: mentions PR 99", true, newFailNotes.some(n => n.key === "ci:testuser/webapp:99"));
const noteText = notificationText(notes3);
assert("notification text counts the new failure", true, /^\d+ new failures?/.test(noteText));
assert("notification text names no repo or title", false, /webapp|api-server|broken|#99/.test(noteText));
assert("notification text counts each kind", "2 new failures, 1 review request",
  notificationText([{ type: "failure" }, { type: "failure" }, { type: "review" }]));

console.log("");
console.log("Test: Disabled notification kinds stay silent but remember state");
data = parseOverview(JSON.stringify($overview2_json));
resetNotifications();
getNewNotifications(data, false, false);
data = parseOverview(JSON.stringify($overview3_json));
assert("failure notes off: nothing fires", 0, getNewNotifications(data, false, true).filter(n => n.type === "failure").length);
assert("re-enabling does not replay the silenced failure", 0, getNewNotifications(data, true, true).filter(n => n.type === "failure").length);

console.log("");
console.log("Test: Hidden repos still notify");
// Visibility is a display choice only: notification scope takes no hidden set.
data = parseOverview(JSON.stringify($overview2_json));
resetNotifications();
getNewNotifications(data, true, true);
data = parseOverview(JSON.stringify($overview3_json));
const hiddenWebapp = repoSet("testuser/webapp");
assert("webapp hidden from the bar", true, getBarSummary(data, hiddenWebapp).total < getBarSummary(data, {}).total);
assert("hidden webapp PR #99 still notifies", true,
  getNewNotifications(data, true, true).some(n => n.key === "ci:testuser/webapp:99"));

console.log("");
console.log("Test: A partially collected repo neither fires nor forgets");
function withMeta(json, patch) {
  const o = JSON.parse(JSON.stringify(json));
  Object.assign(o.meta, patch);
  return JSON.stringify(o);
}
function withoutPr(json, id) {
  const o = JSON.parse(JSON.stringify(json));
  for (const k of Object.keys(o.sections)) o.sections[k] = o.sections[k].filter(p => p.id !== id);
  return o;
}
data = parseOverview(JSON.stringify($overview2_json));
resetNotifications();
getNewNotifications(data, true, true);
// webapp degraded while PR #99 first appears failed: stays quiet
data = parseOverview(withMeta($overview3_json, { stale: true, failed_resources: { "testuser/webapp": ["status:99"] } }));
assert("degraded repo: new failure is quiet", 0,
  getNewNotifications(data, true, true).filter(n => n.key === "ci:testuser/webapp:99").length);
data = parseOverview(JSON.stringify($overview3_json));
assert("recovered repo: failure first seen while degraded fires on recovery", 1,
  getNewNotifications(data, true, true).filter(n => n.key === "ci:testuser/webapp:99").length);
// PR #99 vanishes while webapp is degraded, then returns once collection recovers
data = parseOverview(withMeta(withoutPr($overview3_json, 99), { stale: true, failed_resources: { "testuser/webapp": ["prs"] } }));
getNewNotifications(data, true, true);
data = parseOverview(JSON.stringify($overview3_json));
assert("item missing while degraded does not re-alert on recovery", 0,
  getNewNotifications(data, true, true).filter(n => n.key === "ci:testuser/webapp:99").length);

console.log("");
console.log("Test: Other repos keep notifying while one repo is degraded");
data = parseOverview(JSON.stringify($overview2_json));
resetNotifications();
getNewNotifications(data, true, true);
data = parseOverview(withMeta($overview3_json, { stale: true, failed_resources: { "testuser/api-server": ["runs"] } }));
assert("healthy webapp still fires while api-server is degraded", true,
  getNewNotifications(data, true, true).some(n => n.key === "ci:testuser/webapp:99"));

console.log("");
console.log("Test: A wholly re-emitted stale snapshot fires nothing");
data = parseOverview(JSON.stringify($overview2_json));
resetNotifications();
getNewNotifications(data, true, true);
data = parseOverview(withMeta($overview3_json, { stale: true, stale_since: "2026-09-15T10:11:00Z" }));
assert("whole-stale: no notifications", 0, getNewNotifications(data, true, true).length);

console.log("");
console.log("Test: Run failure notifications (legacy and lifecycle shapes)");
data = parseOverview(JSON.stringify($overview4_json));
resetNotifications();
getNewNotifications(data, false, false);
_notifyState = {};
const runsByKey = {};
sectionItems(data, "completed", all).forEach(r => { runsByKey["run:" + r.repo + ":" + r.id] = r; });
const runNotes = getNewNotifications(data, true, false).filter(n => n.key.indexOf("run:") === 0);
const runWorkflows = runNotes.map(n => runsByKey[n.key].workflow);
assert("runs: legacy status failure notifies", true, runWorkflows.some(w => w.indexOf("Deploy") !== -1));
assert("runs: lifecycle conclusion failure notifies", true, runWorkflows.some(w => w.indexOf("release") !== -1));
assert("runs: cancelled run does not notify", false, runWorkflows.some(w => w.indexOf("lint") !== -1));
assert("runs: successful run does not notify", false, runWorkflows.some(w => w === "test"));
const runRepeat = getNewNotifications(data, true, false).filter(n => n.key.indexOf("run:") === 0);
assert("runs: no repeat for same failed run", 0, runRepeat.length);

console.log("");
console.log("Test: runState reports the run result");
const byId = {};
sectionItems(data, "completed", all).concat(sectionItems(data, "running", all)).forEach(r => { byId[r.id] = r; });
assert("runState: lifecycle failure", "failure", runState(byId[600]));
assert("runState: lifecycle cancelled", "cancelled", runState(byId[601]));
assert("runState: lifecycle success", "success", runState(byId[602]));
assert("runState: legacy failure", "failure", runState(byId[499]));
assert("runState: running", "running", runState(byId[501]));
assert("runFailed: lifecycle failure", true, runFailed(byId[600]));
assert("runFailed: cancelled", false, runFailed(byId[601]));

console.log("");
console.log("Test: timeAgo");
assert("null input", "", timeAgo(null));
assert("empty input", "", timeAgo(""));

console.log("");
console.log("Test: Only links on the configured Gitea open");
data = parseOverview(JSON.stringify($overview_json));
assert("same-origin PR link opens", "https://git.example.com/testuser/webapp/pulls/1",
  safeUrl("https://git.example.com/testuser/webapp/pulls/1", giteaUrl()));
assert("other host is refused", "", safeUrl("https://evil.example.net/testuser/webapp/pulls/1", giteaUrl()));
assert("look-alike host is refused", "", safeUrl("https://git.example.com.evil.net/x", giteaUrl()));
assert("userinfo trick is refused", "", safeUrl("https://git.example.com@evil.net/x", giteaUrl()));
assert("other scheme is refused", "", safeUrl("file:///etc/passwd", giteaUrl()));
assert("non-string is refused", "", safeUrl(null, giteaUrl()));
assert("repo page opens", "https://git.example.com/testuser/webapp", repoUrl("testuser/webapp", giteaUrl()));
assert("odd repo name is refused", "", repoUrl("../../evil", giteaUrl()));
data = parseOverview(JSON.stringify(Object.assign($overview_json, { meta: Object.assign({}, $overview_json.meta, { gitea_url: "https://host.example/gitea" }) })));
assert("sub-path install opens its own links", "https://host.example/gitea/a/b/pulls/2", safeUrl("https://host.example/gitea/a/b/pulls/2", giteaUrl()));
assert("sub-path install refuses the bare host", "", safeUrl("https://host.example/other/x", giteaUrl()));
data = parseOverview(JSON.stringify(Object.assign($overview_json, { meta: Object.assign({}, $overview_json.meta, { gitea_url: "https://Git.Example.com:443" }) })));
assert("host case and default port are the same Gitea", "https://git.example.com/a/b/pulls/3", safeUrl("https://git.example.com/a/b/pulls/3", giteaUrl()));
assert("explicit default port on the link is the same Gitea", "https://GIT.example.com:443/a/b", safeUrl("https://GIT.example.com:443/a/b", giteaUrl()));
assert("a different port is another origin", "", safeUrl("https://git.example.com:8443/a/b", giteaUrl()));
assert("a different scheme is another origin", "", safeUrl("http://git.example.com/a/b", giteaUrl()));
data = parseOverview(JSON.stringify(Object.assign($overview_json, { meta: Object.assign({}, $overview_json.meta, { gitea_url: "http://[fd00::10]:3000" }) })));
assert("IPv6 literal Gitea opens its links", "http://[fd00::10]:3000/a/b/pulls/4", safeUrl("http://[fd00::10]:3000/a/b/pulls/4", giteaUrl()));
assert("IPv6 literal Gitea opens repo pages", "http://[fd00::10]:3000/a/b", repoUrl("a/b", giteaUrl()));
assert("another IPv6 host is refused", "", safeUrl("http://[fd00::11]:3000/a/b", giteaUrl()));

console.log("");
console.log("Test: statusIcon coverage");
assert("ci_failed icon", "\u2718", statusIcon("ci_failed"));
assert("approved_ci_passed icon", "\u2714", statusIcon("approved_ci_passed"));
assert("draft icon", "\u25CC", statusIcon("draft"));
assert("conflicted icon", "\u26A0", statusIcon("conflicted"));

console.log("");
console.log("Test: A second library instance answers from passed data");
// The live panel imports Model.js under another URL and gets a fresh
// instance that never parsed anything; it must still read the bar's snapshot.
const vm = require('vm');
const second = vm.createContext({});
vm.runInContext(modelSrc, second);
data = parseOverview(JSON.stringify($overview_json));
assert("second instance: meta from passed data", "testuser", second.getMeta(data).username);
assert("second instance: sections from passed data", sectionItems(data, "all", all).length,
  second.sectionItems(data, "all", all).length);
assert("second instance: section is not empty", true, second.sectionItems(data, "all", all).length > 0);
assert("second instance: visible repos from passed data", visibleRepos(data, {}).join(","),
  second.visibleRepos(data, {}).join(","));

console.log("");
console.log("===========================================");
console.log("Results: " + pass + " passed, " + fail + " failed");
console.log("===========================================");

process.exit(fail > 0 ? 1 : 0);
NODETEST
