package ui

import (
	"fmt"
	"strings"
	"testing"

	"agentpicker/state"
)

// remoteFixture: a mixed session (UC-A: one window handed off, the rest
// local), a session that is remote as a whole (UC-B), and a worktree parked
// on a worker with no session at all.
func remoteFixture() *state.Snapshot {
	mixed := sess("$1", "agentic-harness", now-60,
		win(1, "main", true, active(agent("claude", "harness work", state.StateIdle, 300, 400))),
		win(3, "z", false, active(remote()), shell("zsh", "ls", 10)),
		win(4, "ghidra", false, active(remote())),
	)
	whole := sess("$2", "scheduling-r1", now-120,
		win(1, "agents", true, active(remote()), remote()),
		win(2, "nvim", false, active(remote())),
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
	lines = append(lines, renderGrid(rowCards(whole), 0, 0, 120, 5, now)...)
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
}

// D11: delete on a remote worktree confirms the loss of the only current
// copy, runs rw forget before wt rm, and passes --discard-remote; an
// unreachable worker leaves a pending forget and the delete goes on; a
// forget failure stops before wt rm.
func TestDeleteRemote(t *testing.T) {
	setup := func() (model, *fakeActions) {
		m, f := wtAt(t, 5) // yap-trial, bare
		m.worktree().Remote = true
		return m, f
	}
	m, f := setup()
	f.forget = state.RWForget{Forgotten: []string{"w1"}}
	m = send(t, m, "ctrl+a", "D")
	if want := "delete yap-trial? it is remote; its remote copy, the only current one, goes too [y/N]"; m.pending != confirmDelete || confirmText(m) != want {
		t.Fatalf("confirm %v\n %q\nwant %q", m.pending, confirmText(m), want)
	}
	m = send(t, m, "y")
	expectCallList(t, f, "rw forget /dev/yap-trial", "wt rm /dev/yap-trial --discard-remote", "save")
	if got := input(m); !strings.Contains(got, "deleted yap-trial, remote copy deleted") || strings.Contains(got, "w1") {
		t.Errorf("status %q", got)
	}

	m, f = setup()
	f.forget = state.RWForget{Pending: []string{"w1"}}
	m = send(t, m, "ctrl+a", "D", "y")
	expectCallList(t, f, "rw forget /dev/yap-trial", "wt rm /dev/yap-trial --discard-remote", "save")
	if got := input(m); !strings.Contains(got, "remote copy deleted on next contact") {
		t.Errorf("pending status %q", got)
	}

	m, f = setup()
	f.forgetErr = errFake
	m = send(t, m, "ctrl+a", "D", "y")
	expectCallList(t, f, "rw forget /dev/yap-trial")
	if got := input(m); !strings.Contains(got, "boom") {
		t.Errorf("forget failure %q", got)
	}

	// A local worktree a worker still holds a copy of (handed back
	// earlier): no remote confirm, the copy still goes.
	m, f = wtAt(t, 5)
	f.forget = state.RWForget{Forgotten: []string{"w1", "w2"}}
	m = send(t, m, "ctrl+a", "D", "y")
	expectCallList(t, f, "rw forget /dev/yap-trial", "wt rm /dev/yap-trial", "save")
	if got := input(m); !strings.Contains(got, "2 remote copies deleted") {
		t.Errorf("held status %q", got)
	}
}
