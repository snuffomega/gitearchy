// Model.js — State management for the Gitearchy plugin
.pragma library

// Library state is shared by every bar instance (one per monitor), so it holds
// only the collected snapshot and notification memory. Display choices — the
// hidden repositories and the panel's focused repository — are passed in by
// the caller and never stored here.
var _data = null;
var _initialLoad = true;

// Notification state: keyed by "type:repo:id" → { status, repo, notifiedAt }
var _notifyState = {};

function parseOverview(jsonText) {
    try {
        _data = JSON.parse(jsonText);
        return true;
    } catch (e) {
        return false;
    }
}

function getMeta() {
    if (!_data) return null;
    return _data.meta || {};
}

function resetNotifications() {
    _initialLoad = true;
    _notifyState = {};
}

// Normalize a repository list — an array or a comma-separated string — into a
// { "owner/repo": true } set.
function repoSet(value) {
    var set = {};
    if (!value) return set;
    var list = Array.isArray(value) ? value : String(value).split(",");
    for (var i = 0; i < list.length; i++) {
        var repo = String(list[i] || "").trim();
        if (repo) set[repo] = true;
    }
    return set;
}

function isVisible(repo, hidden) {
    return !(hidden && hidden[repo]);
}

// Repositories with current activity that the bar and panel may show.
function visibleRepos(hidden) {
    if (!_data) return [];
    return (_data.repos || []).filter(function(r) { return isVisible(r, hidden); });
}

// Merge the persisted hidden list with the legacy comma-separated setting.
function hiddenSet(hiddenList, mutedCsv) {
    var set = repoSet(hiddenList);
    var legacy = repoSet(mutedCsv);
    for (var repo in legacy) set[repo] = true;
    return set;
}

// Sorted hidden list after showing or hiding each of the given repositories.
function updateHidden(hidden, repos, hide) {
    var set = {};
    for (var repo in hidden || {}) if (hidden[repo]) set[repo] = true;
    for (var i = 0; i < repos.length; i++) {
        if (hide) set[repos[i]] = true;
        else delete set[repos[i]];
    }
    return Object.keys(set).sort();
}

// Every repository the collector fetched, active or not. Snapshots written
// before known_repos existed fall back to the active ones.
function knownRepos() {
    if (!_data) return [];
    var set = repoSet(_data.known_repos || []);
    var active = _data.repos || [];
    for (var i = 0; i < active.length; i++) set[active[i]] = true;
    return Object.keys(set).sort();
}

// Picker rows matching a case-insensitive search: { repo, shown, active }.
function pickerRows(hidden, query) {
    var needle = String(query || "").trim().toLowerCase();
    var active = repoSet(_data ? _data.repos : []);
    return knownRepos().filter(function(repo) {
        return !needle || repo.toLowerCase().indexOf(needle) !== -1;
    }).map(function(repo) {
        return { repo: repo, shown: isVisible(repo, hidden), active: !!active[repo] };
    });
}

var _sectionKeys = {
    attention: "attention",
    running: "running",
    completed: "recently_completed",
    my_prs: "my_prs",
    review: "review_queue",
    all: "all_prs"
};

// Items of one panel section, limited to visible repositories and, when
// view.focus is set, to that repository. view = { hidden, focus }.
function sectionItems(section, view) {
    if (!_data || !_data.sections) return [];
    var key = _sectionKeys[section] || _sectionKeys.attention;
    var hidden = view ? view.hidden : null;
    var focus = view ? view.focus : "";
    return (_data.sections[key] || []).filter(function(item) {
        return isVisible(item.repo, hidden) && (!focus || item.repo === focus);
    });
}

// Result of a run: its lifecycle status while running, else the conclusion.
// The collector sets conclusion to status for legacy responses.
function runState(run) {
    if (!run) return "";
    if (run.bucket === "running") return run.status || "running";
    return run.conclusion || run.status || "";
}

// Results worth an alert; cancelled and skipped runs are deliberate.
function runFailed(run) {
    var state = runState(run);
    return state === "failure" || state === "error"
        || state === "timed_out" || state === "startup_failure";
}

// Bar summary over visible repositories only.
function getBarSummary(hidden) {
    if (!_data || !_data.sections) return { total: 0, attention: 0, running: 0, failed: 0, review: 0, ready: 0, healthy: true };
    var view = { hidden: hidden, focus: "" };
    var allPrs = sectionItems("all", view);
    var attentionPrs = sectionItems("attention", view);
    var runningJobs = sectionItems("running", view);

    var failed = 0, review = 0, ready = 0;
    for (var i = 0; i < allPrs.length; i++) {
        var p = allPrs[i];
        if (p.status_label === "ci_failed") failed++;
        if (p.status_label === "review_requested") review++;
        if (p.status_label === "approved_ci_passed") ready++;
    }

    return {
        total: allPrs.length,
        attention: attentionPrs.length,
        running: runningJobs.length,
        failed: failed,
        review: review,
        ready: ready,
        healthy: attentionPrs.length === 0 && failed === 0
    };
}

// Current notification-relevant state of every item, across all repositories:
// visibility settings never silence notifications.
function _notifyCandidates() {
    var sections = _data.sections;
    var out = [];
    var prs = sections.all_prs || [];
    for (var i = 0; i < prs.length; i++) {
        var pr = prs[i];
        out.push({
            key: "ci:" + pr.repo + ":" + pr.id, repo: pr.repo, kind: "failure",
            status: pr.status_label, fire: pr.status_label === "ci_failed",
            message: "CI failed on " + pr.repo + " #" + pr.id + ": " + pr.title
        });
    }
    var runs = sections.recently_completed || [];
    for (var j = 0; j < runs.length; j++) {
        var run = runs[j];
        out.push({
            key: "run:" + run.repo + ":" + run.id, repo: run.repo, kind: "failure",
            status: runState(run), fire: runFailed(run),
            message: "Job failed: " + run.workflow + " on " + run.repo
        });
    }
    var queue = sections.review_queue || [];
    for (var k = 0; k < queue.length; k++) {
        var rpr = queue[k];
        out.push({
            key: "review:" + rpr.repo + ":" + rpr.id, repo: rpr.repo, kind: "review",
            status: "review_requested", fire: true,
            message: "Review requested: " + rpr.repo + " #" + rpr.id + ": " + rpr.title
        });
    }
    return out;
}

// Notes for items that newly entered a failed or review-requested state.
//
// A repository whose collection failed this run carries old or missing data,
// so it neither fires nor learns: its previous state is kept untouched until
// it collects cleanly, and a change first seen then fires on recovery. Every other repository notifies normally. A snapshot that
// was re-emitted whole because the repository list itself failed
// (meta.stale_since) is old data everywhere and fires nothing.
function getNewNotifications(notifyFailure, notifyReview) {
    var notes = [];
    if (!_data || !_data.sections) return notes;

    var meta = _data.meta || {};
    var degraded = meta.failed_resources || {};
    var wholeStale = !!meta.stale_since;
    var candidates = _notifyCandidates();
    var now = Date.now();
    var next = {};

    for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        var prev = _notifyState[c.key];
        var enabled = c.kind === "review" ? notifyReview : notifyFailure;
        if (degraded[c.repo] && !_initialLoad) continue;
        var quiet = _initialLoad || wholeStale || !enabled;
        if (!quiet && c.fire && (!prev || prev.status !== c.status)) {
            notes.push({ type: c.kind, message: c.message });
        }
        next[c.key] = { status: c.status, repo: c.repo, notifiedAt: now };
    }

    // Keep memory for items missing from a degraded or wholly stale snapshot
    // so they do not re-alert once collection recovers.
    for (var key in _notifyState) {
        if (next[key]) continue;
        var entry = _notifyState[key];
        if (wholeStale || (degraded[entry.repo] && !next[key])) next[key] = entry;
    }

    _initialLoad = false;
    _notifyState = next;
    return notes;
}

function timeAgo(isoString) {
    if (!isoString) return "";
    var then = new Date(isoString).getTime();
    var now = Date.now();
    var diff = Math.floor((now - then) / 1000);
    if (diff < 60) return "just now";
    if (diff < 3600) return Math.floor(diff / 60) + "m ago";
    if (diff < 86400) return Math.floor(diff / 3600) + "h ago";
    if (diff < 604800) return Math.floor(diff / 86400) + "d ago";
    return new Date(isoString).toLocaleDateString();
}

function statusIcon(label) {
    switch (label) {
        case "ci_failed": return "✘";
        case "changes_requested": return "↺";
        case "review_requested": return "●";
        case "ci_running": return "◦";
        case "approved_ci_passed": return "✔";
        case "approved": return "✓";
        case "ci_passed": return "○";
        case "draft": return "◌";
        case "conflicted": return "⚠";
        default: return "•";
    }
}
