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

// fakeResolve maps a directory or any directory under it to a worktree.
func fakeResolve(roots map[string]worktree.Info) func(string) (worktree.Info, bool) {
	return func(dir string) (worktree.Info, bool) {
		for d := dir; d != "/" && d != "."; d = filepath.Dir(d) {
			if info, ok := roots[d]; ok {
				return info, true
			}
		}
		return worktree.Info{}, false
	}
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

func winIDs(ws []*state.Window) []string {
	var out []string
	for _, w := range ws {
		out = append(out, w.Session.ID+w.ID)
	}
	return out
}

func TestBuildWorktreesMembership(t *testing.T) {
	resolve := fakeResolve(map[string]worktree.Info{
		"/r/a":  {Root: "/r/a", Repo: "a", Branch: "main"},
		"/r/a2": {Root: "/r/a2", Repo: "a", Head: "abc1234"},
		"/r/b":  {Root: "/r/b", Repo: "b", Branch: "dev"},
	})
	rows, mem := buildRows([]paneRow{
		// A subdirectory belongs to its worktree; a pane outside every repo
		// belongs to none.
		{sid: "$1", wid: "@1", widx: 1, pid: "%1", pidx: 0, path: "/r/a/sub"},
		{sid: "$1", wid: "@1", widx: 1, pid: "%2", pidx: 1, path: "/home"},
		// A live agent counts by its cwd, not its pane path.
		{sid: "$1", wid: "@2", widx: 2, pid: "%3", pidx: 0, path: "/r/a", cwd: "/r/b", st: "working"},
		// A window linked into $2 and $1: grouped once, under $1 (tmux
		// order), though $2's copy comes first in the rows.
		{sid: "$2", wid: "@3", widx: 1, pid: "%4", pidx: 0, path: "/r/a2"},
		{sid: "$1", wid: "@3", widx: 3, pid: "%4", pidx: 0, path: "/r/a2"},
	})
	sessions := buildSnapshot(clientLine{}, rows, mem, 0).Sessions
	// Back to tmux order ($1 first here) for a direct call.
	if sessions[0].ID != "$1" {
		sessions[0], sessions[1] = sessions[1], sessions[0]
	}
	ws := buildWorktrees(sessions, "%3", resolve)
	if got, want := roots(ws), []string{"/r/a", "/r/b", "/r/a2"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("roots %v, want %v", got, want)
	}
	a, b, a2 := ws[0], ws[1], ws[2]
	if got := paneIDs(a.Panes); !reflect.DeepEqual(got, []string{"%1"}) {
		t.Errorf("a panes %v", got)
	}
	if got := paneIDs(b.Panes); !reflect.DeepEqual(got, []string{"%3"}) {
		t.Errorf("b panes %v", got)
	}
	if !b.Current || a.Current || a2.Current {
		t.Errorf("current: a=%v b=%v a2=%v", a.Current, b.Current, a2.Current)
	}
	if got := winIDs(a2.Windows); !reflect.DeepEqual(got, []string{"$1@3"}) {
		t.Errorf("linked window under %v, want $1", got)
	}
	if !a2.Detached() || a2.Head != "abc1234" || a.Repo != "a" {
		t.Errorf("a2 = %+v", a2)
	}
	for _, s := range sessions {
		for _, w := range s.Windows {
			for _, p := range w.Panes {
				if (p.ID == "%2") != (p.Worktree == nil) {
					t.Errorf("%s Worktree = %v", p.ID, p.Worktree)
				}
			}
		}
	}
}

// Worktrees sort as sessions do, by last access only: the current one
// last, the rest by the newest member focus stamp. Agent states (awaiting,
// done, working, a newer state change) do not reorder them. Stamps are per
// pane, so the window shared by /r/shared and /r/split counts its focus only
// for /r/shared, whose pane had it.
func TestWorktreeOrder(t *testing.T) {
	info := map[string]worktree.Info{}
	for _, n := range []string{"cur", "aw", "dn", "wk", "plain", "shared", "split"} {
		info["/r/"+n] = worktree.Info{Root: "/r/" + n, Repo: "r", Branch: n}
	}
	rows, mem := buildRows([]paneRow{
		{sid: "$1", wid: "@1", widx: 1, pid: "%1", path: "/r/cur", focus: 1},
		{sid: "$1", wid: "@2", widx: 2, pid: "%2", path: "/r/aw", st: "awaiting", stateAt: 90, focus: 2},
		{sid: "$1", wid: "@3", widx: 3, pid: "%3", path: "/r/dn", st: "finished", stateAt: 80, focus: 3},
		{sid: "$1", wid: "@4", widx: 4, pid: "%4", path: "/r/wk", st: "working", stateAt: 70, focus: 4},
		{sid: "$1", wid: "@5", widx: 5, pid: "%5", path: "/r/plain", focus: 6},
		{sid: "$1", wid: "@6", widx: 6, pid: "%6", path: "/r/shared", focus: 9},
		{sid: "$1", wid: "@6", widx: 6, pid: "%7", pidx: 1, path: "/r/split"},
		{sid: "$1", wid: "@7", widx: 7, pid: "%8", path: "/r/split", focus: 5},
	})
	sessions := buildSnapshot(clientLine{}, rows, mem, 0).Sessions
	ws := buildWorktrees(sessions, "%1", fakeResolve(info))
	sortRows(ws)
	want := []string{"/r/aw", "/r/dn", "/r/wk", "/r/split", "/r/plain", "/r/shared", "/r/cur"}
	if got := roots(ws); !reflect.DeepEqual(got, want) {
		t.Errorf("order %v, want %v", got, want)
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

// Real repositories through the real resolver: a linked worktree, a main
// checkout reached from a subdirectory, a detached HEAD and a non-repo.
func TestSnapshotWorktreesGit(t *testing.T) {
	f := newGitFixture(t)
	api := f.repo("api", "exp/one")
	other := f.repo("other")
	f.git(other[0], "checkout", "-q", "--detach")
	plain := f.path("plain")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatal(err)
	}
	rows, mem := buildRows([]paneRow{
		{sid: "$1", wid: "@1", widx: 1, pid: "%1", path: filepath.Join(api[0], "sub"), focus: 5, attached: true},
		{sid: "$1", wid: "@1", widx: 1, pid: "%2", pidx: 1, path: plain, cwd: api[1], st: "awaiting", stateAt: 3},
		{sid: "$2", wid: "@2", widx: 1, pid: "%3", path: other[0]},
		{sid: "$2", wid: "@2", widx: 1, pid: "%4", pidx: 1, path: plain},
	})
	snap := buildSnapshot(clientLine{session: "$1", pane: "%1"}, rows, mem, 0)
	// Neither other worktree has a focus stamp, so they tie and keep first
	// appearance order (the awaiting agent does not move api-exp-one); the
	// current one is last.
	if got, want := roots(snap.Worktrees), []string{api[1], other[0], api[0]}; !reflect.DeepEqual(got, want) {
		t.Fatalf("worktrees %v, want %v", got, want)
	}
	linked, o, cur := snap.Worktrees[0], snap.Worktrees[1], snap.Worktrees[2]
	if !cur.Current || cur.Branch != "main" || cur.Repo != "api" {
		t.Errorf("current = %+v", cur)
	}
	if linked.Branch != "exp/one" || linked.Repo != "api" || paneIDs(linked.Panes)[0] != "%2" {
		t.Errorf("linked = %+v", linked)
	}
	if !o.Detached() || len(o.Head) != 7 || o.Repo != "other" {
		t.Errorf("detached = %+v", o)
	}
	if !snap.Sessions[1].Attached || snap.Sessions[0].Attached {
		t.Errorf("attached: %v %v", snap.Sessions[0].Attached, snap.Sessions[1].Attached)
	}
}

// BenchmarkBuildSnapshotWorktrees builds a snapshot of 600 panes over 46
// directories: 40 worktrees in 4 repos (36 of them linked), a subdirectory
// per repo, and 2 non-repo directories. Each op uses a fresh resolver, as a
// real load does.
func BenchmarkBuildSnapshotWorktrees(b *testing.B) {
	f := newGitFixture(b)
	var dirs []string
	for r := range 4 {
		roots := f.repo(fmt.Sprintf("repo%d", r), "b1", "b2", "b3", "b4", "b5", "b6", "b7", "b8", "b9")
		dirs = append(dirs, roots...)
		dirs = append(dirs, filepath.Join(roots[0], "sub"))
	}
	dirs = append(dirs, f.path(".home"), f.base)
	var rs []paneRow
	for i := range 600 {
		r := paneRow{
			sid: fmt.Sprintf("$%d", i/20), wid: fmt.Sprintf("@%d", i/4), widx: i / 4 % 5, pid: fmt.Sprintf("%%%d", i),
			pidx: i % 4, path: dirs[i%len(dirs)], focus: int64(i), attached: i < 20,
		}
		if i%3 == 0 {
			r.st, r.cwd, r.stateAt = "working", dirs[(i/3)%len(dirs)], int64(i)
		}
		rs = append(rs, r)
	}
	rows, mem := buildRows(rs)
	cl := clientLine{session: "$0", pane: "%0"}
	snap := buildSnapshot(cl, rows, mem, 0)
	if len(snap.Worktrees) != 40 {
		b.Fatalf("only %d worktrees", len(snap.Worktrees))
	}
	b.ReportAllocs()
	for b.Loop() {
		buildSnapshot(cl, rows, mem, 0)
	}
}
