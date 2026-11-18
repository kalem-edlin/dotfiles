package ui

import (
	"fmt"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"agentpicker/state"
)

// remoteAgent is a remote pane carrying a worker agent's state, mirrored
// onto it by rw (R1): an agent like a local one, without memory.
func remoteAgent(kind, name string, st state.State, ago int64) *state.Pane {
	p := agent(kind, name, st, ago, 0)
	p.Command, p.Remote, p.MemKB, p.HasMem = "ssh", true, 0, false
	return p
}

// remoteFixture: a mixed session (UC-A: one window handed off, the rest
// local), a session that is remote as a whole (UC-B), and a worktree parked
// on a worker with no session at all. Remote agents show their mirrored
// state (R1): Working in the mixed session, Awaiting and one disconnected
// in the remote one.
func remoteFixture() *state.Snapshot {
	mixed := sess("$1", "agentic-harness", now-60,
		win(1, "main", true, active(agent("claude", "harness work", state.StateIdle, 300, 400))),
		win(3, "z", false, active(remoteAgent("pi", "ghidra batch", state.StateWorking, 120)), shell("zsh", "ls", 10)),
		win(4, "ghidra", false, active(remote())),
	)
	whole := sess("$2", "scheduling-r1", now-120,
		win(1, "agents", true, active(remoteAgent("claude", "r1 builds", state.StateAwaiting, 30)), remote()),
		win(2, "nvim", false, active(remote())),
		win(3, "old", false, active(remoteAgent("claude", "old chat", state.StateDisconnected, 900))),
	)
	t := &state.Worktree{Root: "/dev/parked", Name: "parked", Repo: "content-engine", Branch: "exp/parked", ActiveAt: now - 9000, Remote: true}
	return &state.Snapshot{CurrentID: "$9", Sessions: []*state.Session{mixed, whole},
		Worktrees: []*state.Worktree{t}, Now: now}
}

// D10: the parked worktree row and the all-remote session row say remote
// (the parked one with zero panes); the mixed session row does not, its
// remote windows' cards do, and memory shows local memory only.
func TestGoldenRemote(t *testing.T) {
	snap := remoteFixture()
	m := resize(newModel(&fakeActions{next: snap}, snap, nil), 120, 36)
	var lines []string
	for i, r := range m.rows {
		lines = append(lines, renderRow(m.listRow(r, nil, false), m.memWidth(), 120, i == 0, now))
	}
	mixed, whole := snap.Sessions[0], snap.Sessions[1]
	lines = append(lines, renderGrid(rowCards(mixed), 0, 0, 120, 5, now)...)
	lines = append(lines, renderGrid(rowCards(whole), 0, 0, 120, 10, now)...)
	checkWidths(t, "remote", lines, 120)
	golden(t, "remote_120", plain(lines))
	golden(t, "remote_120_styled", strings.Join(lines, "\n")+"\n")

	var got []string
	for _, c := range rowCards(mixed) {
		got = append(got, fmt.Sprintf("%d:%v", c.win.Index, c.remote))
	}
	if want := "1:false 3:true 4:true"; strings.Join(got, " ") != want {
		t.Errorf("mixed cards remote = %v, want %s", got, want)
	}
	for _, c := range rowCards(whole) {
		if c.remote {
			t.Errorf("whole-remote row card %d is marked; the row says it", c.win.Index)
		}
	}
	if mixed.AllRemote() || !whole.AllRemote() || !snap.Worktrees[0].AllRemote() {
		t.Errorf("AllRemote mixed=%v whole=%v parked=%v", mixed.AllRemote(), whole.AllRemote(), snap.Worktrees[0].AllRemote())
	}
	if got := memLabel(mixed.Members()); got != "410M" {
		t.Errorf("mixed memory %q, want local only", got)
	}
	if n, _ := agentSummary(whole.Members()); n != 2 {
		t.Errorf("remote agents counted %d, want 2 (a disconnected one included)", n)
	}
}

// R1: the Working guard covers a remote agent like a local one; a
// disconnected one (state unknown) does not block.
func TestRefuseRemoteWorking(t *testing.T) {
	tr := &state.Worktree{Name: "scheduling-r1", Panes: []*state.Pane{
		remoteAgent("claude", "r1", state.StateWorking, 10), remote(),
	}}
	if err := refuseChange(tr, "delete"); err == nil || err.Error() != "refusing to delete scheduling-r1: an agent is working in it" {
		t.Errorf("remote working: %v", err)
	}
	tr.Panes[0].State = state.StateDisconnected
	if err := refuseChange(tr, "delete"); err != nil {
		t.Errorf("remote disconnected: %v", err)
	}
}

// D11: whether the root is remote is read at C-a D (Actions.RootRemote),
// not from the snapshot. A remote root confirms the loss of the only
// current copy and wt rm gets --discard-remote; wt rm owns rw forget, and
// its "remote" reply lands on the status line.
func TestDeleteRemote(t *testing.T) {
	m, f := wtAt(t, 5) // yap-trial, bare; the snapshot says local
	f.remote = map[string]bool{"/dev/yap-trial": true}
	f.wtResult = map[string]state.WTResult{"rm": {Removed: "/dev/yap-trial", Remote: "deleted"}}
	m = send(t, m, "ctrl+a", "D")
	if want := "delete yap-trial? it is remote; its remote copy, the only current one, goes too [y/N]"; m.pending != confirmDelete || confirmText(m) != want {
		t.Fatalf("confirm %v\n %q\nwant %q", m.pending, confirmText(m), want)
	}
	m = send(t, m, "y")
	expectCallList(t, f, "wt rm /dev/yap-trial --discard-remote", "save")
	if got := input(m); !strings.Contains(got, "deleted yap-trial, remote copy deleted") {
		t.Errorf("status %q", got)
	}

	// An unreachable worker: deleted here, the copy on next contact.
	m, f = wtAt(t, 5)
	f.remote = map[string]bool{"/dev/yap-trial": true}
	f.wtResult = map[string]state.WTResult{"rm": {Removed: "/dev/yap-trial", Remote: "pending"}}
	m = send(t, m, "ctrl+a", "D", "y")
	if got := input(m); !strings.Contains(got, "remote copy deleted on next contact") {
		t.Errorf("pending status %q", got)
	}

	// Local at the key, handed off before wt ran: wt refuses (exit 5, "is
	// remote"), nothing is deleted, and the line says what to do.
	m, f = wtAt(t, 5)
	f.wtErrs = map[string][]error{"rm": {wtErr("rm", state.WTRefused, "/dev/yap-trial is remote and its remote copy is the only current one: hand it back first (rw handback), or pass --discard-remote")}}
	m = send(t, m, "ctrl+a", "D")
	if confirmText(m) != "delete yap-trial to Trash? [y/N]" {
		t.Errorf("local confirm %q", confirmText(m))
	}
	m = send(t, m, "y")
	expectCallList(t, f, "wt rm /dev/yap-trial")
	if got := input(m); !strings.Contains(got, "yap-trial is remote; nothing deleted. C-a D again to confirm") {
		t.Errorf("race %q", got)
	}

	// A local worktree a worker still holds a copy of (handed back
	// earlier): the plain confirm, and wt's reply on the line.
	m, f = wtAt(t, 5)
	f.wtResult = map[string]state.WTResult{"rm": {Removed: "/dev/yap-trial", Remote: "kept"}}
	m = send(t, m, "ctrl+a", "D", "y")
	expectCallList(t, f, "wt rm /dev/yap-trial", "save")
	if got := input(m); !strings.Contains(got, "rw missing, remote copy kept") {
		t.Errorf("kept status %q", got)
	}

	// A missing row that is remote is confirmed too, not pruned at once.
	m, f = wtAt(t, 6) // content-engine-9, missing
	f.remote = map[string]bool{"/dev/content-engine-9": true}
	if m = send(t, m, "ctrl+a", "D"); m.pending != confirmDelete {
		t.Fatalf("missing remote: no confirm (%q)", input(m))
	}
	expectCallList(t, f)
	m = send(t, m, "y")
	expectCallList(t, f, "wt rm /dev/content-engine-9 --discard-remote", "save")
}

// Opening a window or a bare row's session shows a busy line and ignores
// keys until it answers: in a remote root rw open runs over ssh.
func TestOpenBusy(t *testing.T) {
	m, f := wtAt(t, 5) // yap-trial, bare
	f.remote = map[string]bool{"/dev/yap-trial": true}
	m, cmd := sendKey(m, "enter")
	if cmd == nil || m.busy != "opening yap-trial remote …" {
		t.Fatalf("busy %q", m.busy)
	}
	m, _ = sendKey(m, "x")
	if m.query.Value() != "" {
		t.Errorf("a key went through while busy: %q", m.query.Value())
	}
	if got := input(m); !strings.Contains(got, "opening yap-trial remote") {
		t.Errorf("line %q", got)
	}

	m, _ = wtAt(t, 0) // roll-hiring, local
	m = send(t, m, "ctrl+a", "w")
	m, _ = sendKey(m, "enter")
	if m.busy != "opening window …" {
		t.Errorf("window busy %q", m.busy)
	}
}

// sendKey feeds one key and returns the command unrun.
func sendKey(m model, k string) (model, tea.Cmd) {
	nm, cmd := m.Update(keyMsg(k))
	return nm.(model), cmd
}
