package tmuxio

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"agentpicker/state"
	"agentpicker/worktree"
)

// paneRow is one list-panes record. Agent panes get @agent_pid pid+1000,
// which mem must list for the agent to count as live.
type paneRow struct {
	sid, wid, pid string
	widx, pidx    int
	path, cwd     string // pane_current_path, @agent_cwd
	st            string // @agent_state, "" for no agent
	focus         int64
	stateAt       int64
	attached      bool
}

func (r paneRow) fields(n int) []string {
	f := make([]string, nFields)
	f[fSessionID], f[fSessionName] = r.sid, "s"+strings.TrimPrefix(r.sid, "$")
	f[fWindowID], f[fWindowIndex], f[fWindowName] = r.wid, fmt.Sprint(r.widx), "w"+r.wid
	f[fPaneID], f[fPaneIndex], f[fPanePID] = r.pid, fmt.Sprint(r.pidx), fmt.Sprint(n)
	f[fCommand], f[fPath], f[fAgentCwd] = "zsh", r.path, r.cwd
	if r.focus != 0 {
		f[fFocusAt] = fmt.Sprint(r.focus)
	}
	if r.st != "" {
		f[fAgentKind], f[fAgentState], f[fAgentPID] = "claude", r.st, fmt.Sprint(n+1000)
		f[fStateAt] = fmt.Sprint(r.stateAt)
	}
	if r.attached {
		f[fAttached] = "1"
	}
	return f
}

// buildRows numbers panes from 1 and lists every pid as alive.
func buildRows(rs []paneRow) ([][]string, map[int]int64) {
	var rows [][]string
	mem := map[int]int64{}
	for i, r := range rs {
		n := i + 1
		rows = append(rows, r.fields(n))
		mem[n], mem[n+1000] = 1, 1
	}
	return rows, mem
}

func roots(ws []*state.Worktree) []string {
	var out []string
	for _, w := range ws {
		out = append(out, w.Root)
	}
	return out
}

func paneIDs(ps []*state.Pane) []string {
	var out []string
	for _, p := range ps {
		out = append(out, p.ID)
	}
	return out
}

// entry is a discovered worktree named after its root's basename.
func entry(root, repo, branch string, activeAt int64) worktree.Entry {
	return worktree.Entry{Info: worktree.Info{Root: root, Repo: repo, Branch: branch},
		Name: filepath.Base(root), ActiveAt: activeAt}
}

// named renames the sessions of rows: sid -> name.
func named(rows [][]string, names map[string]string) [][]string {
	for _, f := range rows {
		if n, ok := names[f[fSessionID]]; ok {
			f[fSessionName] = n
		}
	}
	return rows
}

// A session belongs to the worktree named like it (V1), whatever its panes'
// directories; a name shared by two worktrees goes to the one holding a
// pane; '.' in a directory name matches tmux's '_'; a session named after
// no worktree stays a plain session.
func TestBuildWorktreesByName(t *testing.T) {
	entries := []worktree.Entry{
		entry("/r/a", "a", "main", 0),
		entry("/r/b", "b", "dev", 0),
		entry("/org/a", "a2", "main", 0), // another clone named a
		entry("/r/v1.2", "a", "rel", 0),
		entry("/r/idle", "a", "old", 0),
	}
	rows, mem := buildRows([]paneRow{
		// Session b sits in /r/a: the directory does not move it.
		{sid: "$1", wid: "@1", widx: 1, pid: "%1", path: "/r/a/sub"},
		{sid: "$1", wid: "@2", widx: 2, pid: "%2", path: "/home", cwd: "/r/a", st: "working"},
		// Session a has a pane in /org/a, so it takes that clone.
		{sid: "$2", wid: "@3", widx: 1, pid: "%3", path: "/org/a/x"},
		{sid: "$3", wid: "@4", widx: 1, pid: "%4", path: "/r/v1.2"},
		{sid: "$4", wid: "@5", widx: 1, pid: "%5", path: "/r/b"},
	})
	rows = named(rows, map[string]string{"$1": "b", "$2": "a", "$3": "v1_2", "$4": "home"})
	snap := buildSnapshot(clientLine{session: "$1"}, rows, mem, 0, entries, ownership{})
	by := map[string]*state.Worktree{}
	for _, t := range snap.Worktrees {
		by[t.Root] = t
	}
	if len(by) != 5 {
		t.Fatalf("worktrees %v", roots(snap.Worktrees))
	}
	sess := func(root string) string {
		if s := by[root].Session; s != nil {
			return s.ID
		}
		return "-"
	}
	for root, want := range map[string]string{"/r/a": "-", "/r/b": "$1", "/org/a": "$2", "/r/v1.2": "$3", "/r/idle": "-"} {
		if got := sess(root); got != want {
			t.Errorf("%s session %s, want %s", root, got, want)
		}
	}
	b := by["/r/b"]
	if got := paneIDs(b.Panes); !reflect.DeepEqual(got, []string{"%1", "%2"}) || len(b.Windows) != 2 || !b.Current {
		t.Errorf("b panes %v windows %d current %v", got, len(b.Windows), b.Current)
	}
	if by["/org/a"].Current || by["/r/a"].Current {
		t.Error("only the client's session's worktree is current")
	}
	for _, s := range snap.Sessions {
		for _, w := range s.Windows {
			for _, p := range w.Panes {
				if (s.ID == "$4") != (p.Worktree == nil) {
					t.Errorf("%s Worktree = %v", p.ID, p.Worktree)
				}
			}
		}
	}
	// With no pane in either clone, the first discovered wins.
	rows, mem = buildRows([]paneRow{{sid: "$1", wid: "@1", widx: 1, pid: "%1", path: "/tmp"}})
	rows = named(rows, map[string]string{"$1": "a"})
	snap = buildSnapshot(clientLine{}, rows, mem, 0, entries, ownership{})
	for _, t2 := range snap.Worktrees {
		if (t2.Session != nil) != (t2.Root == "/r/a") {
			t.Errorf("%s has session %v", t2.Root, t2.Session != nil)
		}
	}
}

// Worktrees sort by last activity: a session's last access (focus stamps
// or attach) or its agents' newest state change when it has one (D95),
// else the HEAD or index mtime. The current one is last.
func TestWorktreeOrder(t *testing.T) {
	entries := []worktree.Entry{
		entry("/r/cur", "r", "cur", 1),
		entry("/r/aw", "r", "aw", 0),
		entry("/r/old", "r", "old", 3), // no session, committed at 3
		entry("/r/wk", "r", "wk", 0),
		entry("/r/new", "r", "new", 8), // no session, committed at 8
		entry("/r/plain", "r", "plain", 99),
	}
	rows, mem := buildRows([]paneRow{
		{sid: "$1", wid: "@1", widx: 1, pid: "%1", focus: 1},
		{sid: "$2", wid: "@2", widx: 1, pid: "%2", st: "awaiting", stateAt: 90, focus: 2},
		{sid: "$3", wid: "@3", widx: 1, pid: "%3", st: "working", stateAt: 70, focus: 5},
		// A session with no stamp falls back to the mtime.
		{sid: "$4", wid: "@4", widx: 1, pid: "%4"},
	})
	rows = named(rows, map[string]string{"$1": "cur", "$2": "aw", "$3": "wk", "$4": "plain"})
	snap := buildSnapshot(clientLine{session: "$1"}, rows, mem, 0, entries, ownership{})
	want := []string{"/r/old", "/r/new", "/r/wk", "/r/aw", "/r/plain", "/r/cur"}
	if got := roots(snap.Worktrees); !reflect.DeepEqual(got, want) {
		t.Errorf("order %v, want %v", got, want)
	}
	// The merged list puts plain sessions among them by the same key.
	rows, mem = buildRows([]paneRow{
		{sid: "$1", wid: "@1", widx: 1, pid: "%1", focus: 1},
		{sid: "$5", wid: "@5", widx: 1, pid: "%5", focus: 4},
	})
	rows = named(rows, map[string]string{"$1": "cur", "$5": "home"})
	snap = buildSnapshot(clientLine{session: "$1"}, rows, mem, 0, entries, ownership{})
	var got []string
	for _, r := range state.ListRows(snap.Worktrees, snap.Sessions) {
		got = append(got, r.RowID())
	}
	want = []string{"/r/aw", "/r/wk", "/r/old", "$5", "/r/new", "/r/plain", "/r/cur"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("list %v, want %v", got, want)
	}
}

// gitFixture runs real git, isolated from the user's config, under a temp
// dir with its symlinks resolved (git writes real paths into .git files).
type gitFixture struct {
	tb   testing.TB
	base string
}

func newGitFixture(tb testing.TB) *gitFixture {
	tb.Helper()
	if gitPath == "" {
		tb.Skip("git not installed")
	}
	base, err := filepath.EvalSymlinks(tb.TempDir())
	if err != nil {
		tb.Fatal(err)
	}
	return &gitFixture{tb: tb, base: base}
}

func (f *gitFixture) path(rel string) string { return filepath.Join(f.base, rel) }

func (f *gitFixture) git(dir string, args ...string) {
	f.tb.Helper()
	cmd := exec.Command(gitPath, append([]string{"-C", dir}, args...)...)
	home := f.path(".home")
	cmd.Env = []string{
		"PATH=/bin:/usr/bin", "HOME=" + home, "XDG_CONFIG_HOME=" + filepath.Join(home, ".config"),
		"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null", "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Fixture", "GIT_AUTHOR_EMAIL=fixture@example.invalid",
		"GIT_COMMITTER_NAME=Fixture", "GIT_COMMITTER_EMAIL=fixture@example.invalid",
		"GIT_TERMINAL_PROMPT=0",
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		f.tb.Fatalf("git %v: %v\n%s", args, err, out)
	}
}

// repo creates a main checkout on main with one commit, plus a linked
// worktree beside it per branch, and returns the roots, main first.
func (f *gitFixture) repo(name string, branches ...string) []string {
	f.tb.Helper()
	main := f.path(name)
	if err := os.MkdirAll(filepath.Join(main, "sub"), 0o755); err != nil {
		f.tb.Fatal(err)
	}
	f.git(main, "init", "-q", "-b", "main")
	f.git(main, "commit", "-q", "--allow-empty", "-m", "init")
	out := []string{main}
	for _, b := range branches {
		root := f.path(name + "-" + strings.ReplaceAll(b, "/", "-"))
		f.git(main, "worktree", "add", "-q", "-b", b, root)
		out = append(out, root)
	}
	return out
}

// Load discovers the worktrees under AGENT_SESSIONS_DEV_ROOT once per
// run: a later Load reuses the scan, and rediscover forces a new one.
func TestLoadDiscoversOnce(t *testing.T) {
	reset(t)
	f := newGitFixture(t)
	api := f.repo("dev/api", "exp/one")
	t.Setenv(worktree.DevRootEnv, f.path("dev"))
	r := paneRow{sid: "$1", wid: "@1", widx: 1, pid: "%1", path: "/x"}
	fields := r.fields(1)
	fields[fSessionName] = filepath.Base(api[1])
	fixture(t, "out-list-panes", strings.Join(fields, sep)+"\n")

	a := New("").(*actions)
	snap, err := a.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := roots(snap.Worktrees); len(got) != 2 {
		t.Fatalf("worktrees %v", got)
	}
	for _, wt := range snap.Worktrees {
		if (wt.Root == api[1]) != (wt.Session != nil) || wt.Repo != "api" {
			t.Errorf("%s: repo %s session %v", wt.Root, wt.Repo, wt.Session != nil)
		}
	}
	f.git(api[0], "worktree", "add", "-q", "-b", "exp/two", f.path("dev/api-exp-two"))
	if snap, _ = a.Load(); len(snap.Worktrees) != 2 {
		t.Errorf("second load rescanned: %v", roots(snap.Worktrees))
	}
	a.rediscover = true
	if snap, _ = a.Load(); len(snap.Worktrees) != 3 {
		t.Errorf("rediscover: %v", roots(snap.Worktrees))
	}
}

// BenchmarkBuildSnapshotWorktrees builds a snapshot of 600 panes in 30
// sessions against 100 discovered worktrees, 20 of them named like a
// session. Discovery itself is timed by worktree's BenchmarkDiscover.
func BenchmarkBuildSnapshotWorktrees(b *testing.B) {
	var entries []worktree.Entry
	for i := range 100 {
		entries = append(entries, entry(fmt.Sprintf("/r/repo%d/wt%d", i%4, i), fmt.Sprintf("repo%d", i%4), "main", int64(i)))
	}
	var rs []paneRow
	for i := range 600 {
		r := paneRow{
			sid: fmt.Sprintf("$%d", i/20), wid: fmt.Sprintf("@%d", i/4), widx: i / 4 % 5, pid: fmt.Sprintf("%%%d", i),
			pidx: i % 4, path: "/r", focus: int64(i), attached: i < 20,
		}
		if i%3 == 0 {
			r.st, r.stateAt = "working", int64(i)
		}
		rs = append(rs, r)
	}
	rows, mem := buildRows(rs)
	names := map[string]string{}
	for i := range 30 {
		names[fmt.Sprintf("$%d", i)] = fmt.Sprintf("wt%d", i*3)
	}
	rows = named(rows, names)
	cl := clientLine{session: "$0", pane: "%0"}
	snap := buildSnapshot(cl, rows, mem, 0, entries, ownership{})
	n := 0
	for _, t := range snap.Worktrees {
		if t.Session != nil {
			n++
		}
	}
	if n != 30 {
		b.Fatalf("%d worktrees with a session", n)
	}
	b.ReportAllocs()
	for b.Loop() {
		buildSnapshot(cl, rows, mem, 0, entries, ownership{})
	}
}
