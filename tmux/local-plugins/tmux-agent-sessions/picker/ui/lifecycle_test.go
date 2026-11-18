package ui

import (
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"agentpicker/inspect"
	"agentpicker/state"
)

// Rows of wtFixture by ups from the start (see wtAt): 0 roll-hiring (an
// Awaiting and a Done agent, nvim), 1 content-engine-1 (Working), 2
// content-engine-5 (detached, Done), 3 content-engine-7 (bare, locked), 4
// misc (plain session), 5 yap-trial (bare), 6 content-engine-9 (missing).

func input(m model) string { return ansi.Strip(m.renderInput()) }

// confirmText is the input line up to and including [y/N], trimmed: the
// whole confirm, so nothing else (dirty counts, agents) can hide in it.
func confirmText(m model) string {
	l := input(m)
	if i := strings.Index(l, "[y/N]"); i >= 0 {
		l = l[:i+len("[y/N]")]
	}
	return strings.TrimSpace(l)
}

func wtErr(op string, code int, msg string) error {
	return &state.WTError{Op: op, Code: code, Msg: msg}
}

func expectCallList(t *testing.T, f *fakeActions, want ...string) {
	t.Helper()
	if len(want) == 0 && len(f.calls) == 0 {
		return
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Errorf("calls:\n %q\nwant\n %q", f.calls, want)
	}
}

// C-a c prompts for a branch, runs wt new on the row's repo, then opens the
// new directory's session there and exits. Nothing is installed.
func TestNewWorktreeFromMain(t *testing.T) {
	m, f := wtAt(t, 0)
	f.wtResult = map[string]state.WTResult{"new": {Path: "/dev/b3.x", Branch: "b3"}}
	m = send(t, m, "ctrl+a", "c")
	if m.pending != promptNewWorktree || !strings.Contains(input(m), "new worktree from main: ") {
		t.Fatalf("prompt: %v %q", m.pending, input(m))
	}
	m = send(t, m, "b", "3", "enter")
	expectCallList(t, f, "wt new /dev/roll-hiring b3 from=", "create b3_x -c /dev/b3.x")
	if !m.quitting {
		t.Error("the picker exits after the new session")
	}
}

// C-a C bases the worktree on the row's branch, or its commit when detached.
func TestNewWorktreeFromBranch(t *testing.T) {
	m, f := wtAt(t, 0)
	f.wtResult = map[string]state.WTResult{"new": {Path: "/dev/b4"}}
	m = send(t, m, "ctrl+a", "C")
	if !strings.Contains(input(m), "new worktree from exp/roll-hiring: ") {
		t.Fatalf("label %q", input(m))
	}
	m = send(t, m, "b", "4", "enter")
	expectCallList(t, f, "wt new /dev/roll-hiring b4 from=exp/roll-hiring", "create b4 -c /dev/b4")

	m, f = wtAt(t, 2) // content-engine-5, detached
	m = send(t, m, "ctrl+a", "C")
	if !strings.Contains(input(m), "new worktree from 1a2b3c4: ") || m.targetFrom != "1a2b3c4" {
		t.Errorf("detached label %q from %q", input(m), m.targetFrom)
	}
	// An empty name cancels, as at the other prompts.
	m = send(t, m, "enter")
	expectCallList(t, f)
}

// A wt failure stays open, reloads (a partial new may have left a worktree)
// and shows wt's message cut to the width.
func TestNewWorktreeError(t *testing.T) {
	m, f := wtAt(t, 0)
	m = resize(m, 40, 24)
	f.wtErrs = map[string][]error{"new": {wtErr("new", 5, "target exists: /dev/a-very-long-path/that/does/not/fit")}}
	loads := f.loads
	m = send(t, m, "ctrl+a", "c", "x", "enter")
	expectCallList(t, f, "wt new /dev/roll-hiring x from=")
	if m.quitting || f.loads != loads+1 {
		t.Errorf("quitting=%v loads=%d", m.quitting, f.loads-loads)
	}
	line := input(m)
	if !strings.Contains(line, "wt new: target exists") || width(m.renderInput()) != 40 || !strings.Contains(line, "…") {
		t.Errorf("error line %q (%d)", line, width(m.renderInput()))
	}
}

// While wt runs the input line says so and keys wait.
func TestLifecycleBusy(t *testing.T) {
	m, _ := wtAt(t, 3) // content-engine-7, locked: wt status gives the reason
	nm, _ := m.Update(keyMsg("ctrl+a"))
	m = nm.(model)
	nm, cmd := m.Update(keyMsg("D"))
	m = nm.(model)
	if cmd == nil || m.busy != "running wt status …" || !strings.Contains(input(m), "running wt status …") {
		t.Fatalf("busy %q cmd %v line %q", m.busy, cmd != nil, input(m))
	}
	nm, _ = m.Update(keyMsg("x"))
	if mm := nm.(model); mm.query.Value() != "" || mm.armed {
		t.Errorf("key during wt: query %q", mm.query.Value())
	}
	nm, _ = m.Update(cmd())
	if mm := nm.(model); mm.busy != "" || mm.pending != confirmDelete {
		t.Errorf("after status: busy %q pending %v", mm.busy, mm.pending)
	}
}

func TestRepurpose(t *testing.T) {
	m, f := wtAt(t, 3) // content-engine-7: bare and locked, which repurpose allows
	m.git["/dev/content-engine-7"] = inspect.Git{Branch: "exp/heavy"}
	f.wtResult = map[string]state.WTResult{"repurpose": {Path: "/dev/content-engine-7", Branch: "next",
		PreviousBranch: "exp/heavy", NeedsInstall: true, NeedsPods: true}}
	m = send(t, m, "ctrl+a", "x")
	if m.pending != promptRepurpose || !strings.Contains(input(m), "repurpose content-engine-7 to branch: ") {
		t.Fatalf("prompt %v %q", m.pending, input(m))
	}
	m = send(t, m, "n", "e", "x", "t", "enter")
	expectCallList(t, f, "wt repurpose /dev/content-engine-7 next")
	if m.quitting || rowRoot(m) != "/dev/content-engine-7" {
		t.Errorf("stays open on the row: %v %q", m.quitting, rowRoot(m))
	}
	// The result line is short (D105): no install or pods hints.
	if got := strings.TrimSpace(input(m)); !strings.HasPrefix(got, "repurposed content-engine-7 to next") || strings.Contains(got, "needs") {
		t.Errorf("status %q", got)
	}
	if _, ok := m.git["/dev/content-engine-7"]; ok {
		t.Error("the preview's git state is stale after repurpose")
	}
	// The next key clears the result line.
	if m = send(t, m, "ctrl+n"); strings.Contains(input(m), "repurposed") {
		t.Errorf("status kept: %q", input(m))
	}
}

// A dirty tree is stashed without a second question (D105): the branch
// prompt is the only one, and the result line counts what was stashed.
func TestRepurposeDirty(t *testing.T) {
	m, f := wtAt(t, 5) // yap-trial
	f.wtResult = map[string]state.WTResult{"repurpose": {Branch: "next", PreviousBranch: "main", Stashed: true, Stash: "abc1234", StashedChanges: 3}}
	m = send(t, m, "ctrl+a", "x", "n", "e", "x", "t", "enter")
	expectCallList(t, f, "wt repurpose /dev/yap-trial next")
	if m.pending != promptNone || m.err != nil {
		t.Errorf("no confirm: %v %v", m.pending, m.err)
	}
	if got := input(m); !strings.Contains(got, "repurposed yap-trial to next, 3 changes stashed") {
		t.Errorf("status %q", got)
	}
	if got := repurposeStatus("a", state.WTResult{Branch: "b", Stashed: true, StashedChanges: 1}); got != "repurposed a to b, 1 change stashed" {
		t.Errorf("singular %q", got)
	}
	// wt's message stays on an error.
	m, f = wtAt(t, 5)
	f.wtErrs = map[string][]error{"repurpose": {wtErr("repurpose", 5, "branch main is checked out at /dev/x")}}
	m = send(t, m, "ctrl+a", "x", "m", "enter")
	if !strings.Contains(input(m), "wt repurpose: branch main is checked out at /dev/x") {
		t.Errorf("error %q", input(m))
	}
}

// Refusals run nothing: an agent Working, the main worktree (repurpose
// only; delete asks wt status, D102), a missing directory. A plain session
// row ignores every lifecycle key.
func TestLifecycleRefusals(t *testing.T) {
	m, f := wtAt(t, 5) // yap-trial as the main worktree
	m.worktree().Main = true
	if m = send(t, m, "ctrl+a", "x"); m.pending != promptNone || !strings.Contains(input(m), "refusing to repurpose the main worktree: yap-trial") {
		t.Errorf("C-a x main: %q", input(m))
	}
	expectCallList(t, f)

	for _, k := range []string{"x", "D"} {
		m, f := wtAt(t, 1) // content-engine-1, a Working agent
		m = send(t, m, "ctrl+a", k)
		if m.pending != promptNone || !strings.Contains(input(m), "an agent is working in it") {
			t.Errorf("C-a %s working: %v %q", k, m.pending, input(m))
		}
		expectCallList(t, f)

		m, f = wtAt(t, 4) // misc, a plain session
		m = send(t, m, "ctrl+a", k)
		if m.pending != promptNone || m.err != nil || m.busy != "" {
			t.Errorf("C-a %s plain: %v %v", k, m.pending, m.err)
		}
		expectCallList(t, f)
	}
	for _, k := range []string{"c", "C"} {
		m, f := wtAt(t, 1) // new is never refused for a Working agent
		if m = send(t, m, "ctrl+a", k); m.pending != promptNewWorktree {
			t.Errorf("C-a %s working row: %v", k, m.pending)
		}
		m, f = wtAt(t, 6)
		if m = send(t, m, "ctrl+a", k); m.pending != promptNone || !strings.Contains(input(m), "missing") {
			t.Errorf("C-a %s missing: %q", k, input(m))
		}
		m, f = wtAt(t, 4)
		if m = send(t, m, "ctrl+a", k); m.pending != promptNone || m.err != nil {
			t.Errorf("C-a %s plain: %v", k, m.pending)
		}
		expectCallList(t, f)
	}
	// The client's own row is deleted after the client moves to the next
	// most recent session (D108); only a lone session is refused.
	m, f = newWTTest(t)
	for range 7 {
		m = send(t, m, "ctrl+n")
	}
	if rowRoot(m) != "/dev/dotfiles" || !m.worktree().Current {
		t.Fatalf("at %q", rowRoot(m))
	}
	m.worktree().Panes = nil // no Working agent
	cur := m.worktree().Session
	next := m.nextSession(cur)
	if next == nil || next.ID == cur.ID || next.Recency() < cur.Recency()-1e9 {
		t.Fatalf("next session: %+v", next)
	}
	for _, o := range m.snap.Sessions {
		if o.ID != cur.ID && o.Recency() > next.Recency() {
			t.Errorf("next %s is not the most recent: %s", next.Name, o.Name)
		}
	}
	if m = send(t, m, "ctrl+a", "D"); m.pending != confirmDelete || m.label != "delete dotfiles to Trash? " {
		t.Errorf("current row confirm: %v %q", m.pending, m.label)
	}
	m = send(t, m, "y")
	expectCallList(t, f, "switch "+next.ID+" - -", "kill-session "+cur.ID, "rw forget /dev/dotfiles", "wt rm /dev/dotfiles", "save")
	if !strings.Contains(input(m), "deleted dotfiles") {
		t.Errorf("current row result: %q", input(m))
	}
	m, f = newWTTest(t)
	for range 7 {
		m = send(t, m, "ctrl+n")
	}
	m.worktree().Panes = nil
	m.snap.Sessions = []*state.Session{m.worktree().Session}
	if m = send(t, m, "ctrl+a", "D"); !strings.Contains(input(m), "refusing to delete dotfiles: no other session to switch to") {
		t.Errorf("lone session: %q", input(m))
	}
	expectCallList(t, f)

	m, f = wtAt(t, 6)
	if m = send(t, m, "ctrl+a", "x"); !strings.Contains(input(m), "missing") {
		t.Errorf("C-a x missing: %q", input(m))
	}
	expectCallList(t, f)
}

// D104: after C-a, n and p move rows like ctrl-n and ctrl-p; N stays a
// dead key (D103): no prompt, no wt call, nothing typed, the prefix
// disarmed. A plain session row keeps C-a w (new window) and C-a s (new
// session).
func TestPrefixNP(t *testing.T) {
	for _, row := range []int{0, 4, 6} { // a worktree with a session, a plain session, a missing row
		for _, k := range []string{"n", "ctrl+n", "N", "p", "ctrl+p"} {
			m, f := wtAt(t, row)
			cur := m.cur
			m = send(t, m, "ctrl+a", k)
			if m.pending != promptNone || m.err != nil || m.busy != "" || m.armed || m.query.Value() != "" {
				t.Errorf("row %d C-a %s: pending=%v err=%v query=%q", row, k, m.pending, m.err, m.query.Value())
			}
			want := cur
			switch k {
			case "n", "ctrl+n":
				want = min(cur+1, len(m.matches)-1)
			case "p", "ctrl+p":
				want = max(cur-1, 0)
			}
			if m.cur != want {
				t.Errorf("row %d C-a %s: cur %d, want %d", row, k, m.cur, want)
			}
			expectCallList(t, f)
		}
	}
	m, _ := wtAt(t, 4) // misc
	if m = send(t, m, "ctrl+a", "w"); m.pending != promptNewWindow || m.target == nil || m.target.ID != "$3" {
		t.Errorf("plain C-a w: %v", m.pending)
	}
	m = send(t, m, "esc", "ctrl+a", "s")
	if m.pending != promptNewSession {
		t.Errorf("plain C-a s: %v", m.pending)
	}
}

// C-a D on a linked worktree: one short confirm with no wt status call
// (D105), then on y the session is killed, wt rm moves it to the Trash, a
// background save starts and the short result shows.
func TestDelete(t *testing.T) {
	m, f := wtAt(t, 0)
	f.wtResult = map[string]state.WTResult{"rm": {Removed: "/dev/roll-hiring", Branch: "exp/roll-hiring", TrashedTo: "/home/.Trash/roll-hiring"}}
	m = send(t, m, "ctrl+a", "D")
	if want := "delete roll-hiring to Trash? [y/N]"; m.pending != confirmDelete || confirmText(m) != want {
		t.Fatalf("confirm %v\n %q\nwant %q", m.pending, input(m), want)
	}
	expectCallList(t, f)
	m = send(t, m, "y")
	expectCallList(t, f, "kill-session $2", "rw forget /dev/roll-hiring", "wt rm /dev/roll-hiring", "save")
	if got := strings.TrimSpace(input(m)); m.quitting || !strings.HasPrefix(got, "deleted roll-hiring") || strings.Contains(got, "Trash") {
		t.Errorf("status %q", got)
	}

	// Anything but y cancels, and nothing ran.
	m, f = wtAt(t, 0)
	m = send(t, m, "ctrl+a", "D", "n")
	expectCallList(t, f)

	// A bare row has no session to kill. Dirt is not asked about: it goes
	// to the Trash with the tree.
	m, f = wtAt(t, 5)
	f.wtStatus = state.WTStatus{Branch: "main", Dirty: 2, Untracked: 1}
	m = send(t, m, "ctrl+a", "D")
	if confirmText(m) != "delete yap-trial to Trash? [y/N]" {
		t.Errorf("bare confirm %q", input(m))
	}
	m = send(t, m, "y")
	expectCallList(t, f, "rw forget /dev/yap-trial", "wt rm /dev/yap-trial", "save")
	if m.pending != promptNone {
		t.Errorf("a second confirm opened: %v", m.pending)
	}

	// A failed save start is reported on the result line.
	m, f = wtAt(t, 5)
	f.saveErr = errFake
	m = send(t, m, "ctrl+a", "D", "y")
	if !strings.Contains(input(m), "deleted yap-trial (boom)") {
		t.Errorf("save failure %q", input(m))
	}
}

// Refusals: locked with its reason (wt status), a status error, a kill
// failure that stops before wt rm, a lock wt finds that discovery missed,
// and a missing row wt cannot prune.
func TestDeleteRefusals(t *testing.T) {
	m, f := wtAt(t, 3) // content-engine-7, locked
	f.wtStatus = state.WTStatus{Branch: "exp/heavy", Locked: true, LockReason: "heavy"}
	m = send(t, m, "ctrl+a", "D")
	if m.pending != promptNone || !strings.Contains(input(m), "refusing to delete content-engine-7: locked (heavy)") {
		t.Errorf("locked %q", input(m))
	}
	expectCallList(t, f, "wt status /dev/content-engine-7")

	m, f = wtAt(t, 5)
	m.worktree().Main = true
	f.wtErrs = map[string][]error{"status": {wtErr("status", 1, "not a git worktree: /dev/yap-trial")}}
	if m = send(t, m, "ctrl+a", "D"); m.pending != promptNone || !strings.Contains(input(m), "wt status: not a git worktree") {
		t.Errorf("status error %q", input(m))
	}

	m, f = wtAt(t, 0)
	f.err = errFake
	m = send(t, m, "ctrl+a", "D", "y")
	expectCallList(t, f, "kill-session $2")
	if !strings.Contains(input(m), "boom") {
		t.Errorf("kill failure %q", input(m))
	}

	m, f = wtAt(t, 5)
	f.wtErrs = map[string][]error{"rm": {wtErr("rm", state.WTLocked, "locked: late: /dev/yap-trial (use --force)")}}
	m = send(t, m, "ctrl+a", "D", "y")
	expectCallList(t, f, "rw forget /dev/yap-trial", "wt rm /dev/yap-trial")
	if m.pending != promptNone || !strings.Contains(input(m), "wt rm: locked: late") {
		t.Errorf("late lock %v %q", m.pending, input(m))
	}

	// A missing row that wt cannot prune (locked) shows why.
	m, f = wtAt(t, 6) // content-engine-9, missing
	f.wtErrs = map[string][]error{"rm": {wtErr("rm", state.WTLocked, "locked: keep: /dev/content-engine-9 (use --force)")}}
	m = send(t, m, "ctrl+a", "D")
	expectCallList(t, f, "rw forget /dev/content-engine-9", "wt rm /dev/content-engine-9")
	if !strings.Contains(input(m), "wt rm: locked: keep") {
		t.Errorf("missing %q", input(m))
	}
}

// A missing row: wt rm prunes its registration at once, with nothing to
// confirm or kill (D102).
func TestDeleteMissingPrunes(t *testing.T) {
	m, f := wtAt(t, 6) // content-engine-9
	f.wtResult = map[string]state.WTResult{"rm": {Pruned: "/dev/content-engine-9", Branch: "exp/gone"}}
	loads := f.loads
	m = send(t, m, "ctrl+a", "D")
	expectCallList(t, f, "rw forget /dev/content-engine-9", "wt rm /dev/content-engine-9")
	if m.pending != promptNone || m.err != nil || !strings.Contains(input(m), "pruned content-engine-9") || f.loads != loads+1 {
		t.Errorf("prune: %v %v %q loads+%d", m.pending, m.err, input(m), f.loads-loads)
	}
}

// A main checkout with no linked worktrees is the whole repo: wt status
// checks the linked count, the short confirm names the repo, and y kills
// its session, moves it to the Trash and saves (D102, D105).
func TestDeleteMain(t *testing.T) {
	m, f := wtAt(t, 0) // roll-hiring as content-engine-1's main checkout
	m.worktree().Main = true
	f.wtStatus = state.WTStatus{Main: true, Branch: "exp/roll-hiring", Dirty: 1}
	f.wtResult = map[string]state.WTResult{"rm": {Removed: "/dev/roll-hiring", Main: true, TrashedTo: "/home/.Trash/roll-hiring"}}
	m = send(t, m, "ctrl+a", "D")
	if want := "delete repo content-engine-1 to Trash? [y/N]"; m.pending != confirmDelete || confirmText(m) != want {
		t.Fatalf("confirm %v\n %q\nwant %q", m.pending, input(m), want)
	}
	m = send(t, m, "y")
	expectCallList(t, f, "wt status /dev/roll-hiring", "kill-session $2", "rw forget /dev/roll-hiring", "wt rm /dev/roll-hiring", "save")
	if got := strings.TrimSpace(input(m)); !strings.HasPrefix(got, "deleted repo content-engine-1") || strings.Contains(got, "moved") {
		t.Errorf("status %q", got)
	}
}

// A main checkout that still has linked worktrees: no confirm, the count
// on the error line, and the list narrowed to that repo with the query
// cleared, so the linked worktrees show; a reload keeps the filter (D102).
func TestDeleteMainLinked(t *testing.T) {
	m, f := newWTTest(t)
	m = send(t, m, "h", "i", "r", "i", "n", "g")
	if rowRoot(m) != "/dev/roll-hiring" || m.repo != "" {
		t.Fatalf("at %q repo %q", rowRoot(m), m.repo)
	}
	m.worktree().Main = true
	f.wtStatus = state.WTStatus{Main: true, Branch: "exp/roll-hiring", Linked: 4}
	m = send(t, m, "ctrl+a", "D")
	expectCallList(t, f, "wt status /dev/roll-hiring")
	if m.pending != promptNone || !strings.Contains(input(m), "content-engine-1 still has 4 linked worktrees: delete them first") {
		t.Errorf("refusal %v %q", m.pending, input(m))
	}
	wantRows := []string{"/dev/content-engine-9", "/dev/content-engine-7", "/dev/content-engine-5", "/dev/content-engine-1", "/dev/roll-hiring"}
	if m.repo != "content-engine-1" || m.query.Value() != "" || !reflect.DeepEqual(matchRoots(m), wantRows) {
		t.Errorf("filter %q query %q rows %q", m.repo, m.query.Value(), matchRoots(m))
	}
	if rowRoot(m) != "/dev/roll-hiring" {
		t.Errorf("cursor left the main row: %q", rowRoot(m))
	}
	nm, _ := m.Update(reload(f, nil, ""))
	m = nm.(model)
	if m.repo != "content-engine-1" || !reflect.DeepEqual(matchRoots(m), wantRows) {
		t.Errorf("reload reset the filter: %q %q", m.repo, matchRoots(m))
	}
	// The next key clears the error, not the filter.
	if m = send(t, m, "ctrl+p"); m.err != nil || m.repo != "content-engine-1" {
		t.Errorf("after a key: %v %q", m.err, m.repo)
	}

	m, f = wtAt(t, 5)
	m.worktree().Main = true
	f.wtStatus = state.WTStatus{Main: true, Branch: "main", Linked: 1}
	if m = send(t, m, "ctrl+a", "D"); !strings.Contains(input(m), "yap-trial still has 1 linked worktree: delete them first") || m.repo != "yap-trial" {
		t.Errorf("singular %q %q", input(m), m.repo)
	}
}

// C-a e refreshes the env files of every worktree of the row's repo from
// a fresh pull in its main checkout, and C-a E spreads the row's own files
// instead (D109): one confirm naming the repo and the source, then wt
// env-refresh with the row's root (--here for E); the status line carries
// the counts. A plain session row, a missing row and anything but y do
// nothing.
func TestEnvRefresh(t *testing.T) {
	m, f := wtAt(t, 0) // roll-hiring, repo content-engine-1
	f.wtEnv = state.WTEnvResult{Main: "/dev/roll-hiring", Source: "/dev/roll-hiring", Pulled: true, Files: []string{".env.local", ".env.production"},
		Refreshed: 3, Missing: []string{"/dev/content-engine-9"},
		Worktrees: []state.WTEnvWorktree{{Path: "/dev/content-engine-1", Copied: []string{".env.local"}, Skipped: []string{".env.production"}}}}
	loads := f.loads
	m = send(t, m, "ctrl+a", "e")
	if want := "refresh env of every content-engine-1 worktree from main? [y/N]"; m.pending != confirmEnvRefresh || confirmText(m) != want {
		t.Fatalf("confirm %v\n %q\nwant %q", m.pending, input(m), want)
	}
	expectCallList(t, f)
	m = send(t, m, "y")
	expectCallList(t, f, "wt env-refresh /dev/roll-hiring")
	want := "env refreshed in 3 content-engine-1 worktrees from roll-hiring, pulled, 1 symlink(s) skipped, 1 missing"
	if got := m.status; got != want || m.pending != promptNone || m.err != nil || f.loads != loads+1 {
		t.Errorf("status %q\nwant %q (pending %v err %v loads+%d)", got, want, m.pending, m.err, f.loads-loads)
	}

	// Copied only, one worktree, nothing skipped.
	m, f = wtAt(t, 0)
	f.wtEnv = state.WTEnvResult{Main: "/dev/roll-hiring", Source: "/dev/roll-hiring", Files: []string{".env.local"}, Refreshed: 1}
	m = send(t, m, "ctrl+a", "e", "y")
	if want := "env refreshed in 1 content-engine-1 worktree from roll-hiring, copied only"; m.status != want {
		t.Errorf("status %q want %q", m.status, want)
	}

	// C-a E on a linked worktree: that worktree is the source, --here.
	m, f = wtAt(t, 1) // content-engine-1, linked
	f.wtEnv = state.WTEnvResult{Main: "/dev/roll-hiring", Source: "/dev/content-engine-1", Files: []string{".env.local"}, Refreshed: 3}
	m = send(t, m, "ctrl+a", "E")
	if want := "refresh env of every content-engine-1 worktree from content-engine-1? [y/N]"; m.pending != confirmEnvRefresh || confirmText(m) != want {
		t.Fatalf("E confirm %v\n %q\nwant %q", m.pending, input(m), want)
	}
	m = send(t, m, "y")
	expectCallList(t, f, "wt env-refresh /dev/content-engine-1 --here")
	if want := "env refreshed in 3 content-engine-1 worktrees from content-engine-1, copied only"; m.status != want {
		t.Errorf("E status %q want %q", m.status, want)
	}

	// Anything but y cancels, and nothing ran.
	m, f = wtAt(t, 0)
	m = send(t, m, "ctrl+a", "e", "n")
	expectCallList(t, f)
	if m.pending != promptNone || m.err != nil {
		t.Errorf("cancel: %v %v", m.pending, m.err)
	}

	// wt's failure (a failed pull) shows on the error line; nothing else ran.
	m, f = wtAt(t, 0)
	f.wtErrs = map[string][]error{"env-refresh": {&state.WTError{Op: "env-refresh", Code: 1, Msg: "env pull failed in /dev/roll-hiring (exit 7): nope"}}}
	m = send(t, m, "ctrl+a", "e", "y")
	expectCallList(t, f, "wt env-refresh /dev/roll-hiring")
	if m.err == nil || !strings.Contains(m.err.Error(), "env pull failed in /dev/roll-hiring (exit 7): nope") {
		t.Errorf("pull failure: %v", m.err)
	}

	// A missing row is refused locally; a plain session row ignores the key.
	for _, k := range []string{"e", "E"} {
		m, f = wtAt(t, 6) // content-engine-9, missing
		m = send(t, m, "ctrl+a", k)
		expectCallList(t, f)
		if m.pending != promptNone || m.err == nil || !strings.Contains(m.err.Error(), "worktree directory is missing") {
			t.Errorf("missing row %s: %v %v", k, m.pending, m.err)
		}
		m, f = wtAt(t, 4) // misc
		m = send(t, m, "ctrl+a", k)
		expectCallList(t, f)
		if m.pending != promptNone || m.err != nil {
			t.Errorf("plain row %s: %v %v", k, m.pending, m.err)
		}
	}
}
