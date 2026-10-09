package ui

import (
	"errors"
	"fmt"

	"agentpicker/state"
)

const now = int64(1_800_000_000)

const mb = 1024 // KiB per MiB

// win builds a window and links its panes.
func win(idx int, name string, active bool, panes ...*state.Pane) *state.Window {
	w := &state.Window{ID: fmt.Sprintf("@w%d-%s", idx, name), Index: idx, Name: name, Active: active, Panes: panes}
	for i, p := range panes {
		p.Index = i + 1
		p.Window = w
		if p.ID == "" {
			p.ID = fmt.Sprintf("%%%s.%d", name, i+1)
		}
	}
	return w
}

func sess(id, name string, last int64, windows ...*state.Window) *state.Session {
	s := &state.Session{ID: id, Name: name, LastAttached: last, Windows: windows}
	for _, w := range windows {
		w.Session = s
		w.ID = id + w.ID
	}
	return s
}

func agent(kind, name string, st state.State, ago int64, memMB int64) *state.Pane {
	return &state.Pane{
		Command: kind, AgentKind: kind, AgentName: name, State: st,
		AgentAt: now - ago, StateAt: now - ago, MemKB: memMB * mb, HasMem: true,
	}
}

func shell(cmd, last string, memMB int64) *state.Pane {
	return &state.Pane{Command: cmd, LastCommand: last, MemKB: memMB * mb, HasMem: true}
}

func remote() *state.Pane {
	return &state.Pane{Command: "ssh", Remote: true}
}

func active(p *state.Pane) *state.Pane { p.Active = true; return p }

// focused stamps the pane's @pane_focus_at ago seconds before now.
func focused(ago int64, p *state.Pane) *state.Pane { p.FocusAt = now - ago; return p }

// fixture is six sessions in display order: oldest at the top, the
// client's own session last.
func fixture() *state.Snapshot {
	ss := []*state.Session{
		sess("$1", "infra", 0,
			win(1, "prod-ssh", true, active(remote())),
			win(2, "logs", false, active(shell("kubectl", "kubectl logs -f deploy/api", 45))),
		),
		sess("$2", "roll-carousels-3", now-7200,
			win(1, "advertorials", true,
				active(agent("claude", "carousel copy pass", state.StateAwaiting, 300, 512)),
				shell("nvim", "nvim src/carousel.tsx", 180)),
			win(2, "server", false, active(shell("node", "pnpm dev", 900))),
		),
		sess("$3", "roll-initiative-2", now-3600,
			win(1, "initiative", true, active(agent("claude", "initiative scoring", state.StateDone, 720, 430))),
			win(2, "pi-review", false, active(agent("pi", "review notes", state.StateIdle, 3*3600, 350))),
		),
		sess("$4", "roll-web-funnel-changes", now-600,
			win(1, "special-feature-flags", false,
				active(agent("claude", "funnel step refactor", state.StateWorking, 120, 610)),
				focused(40, agent("pi", "copy audit", state.StateDone, 40, 290)),
				shell("zsh", "pnpm test --watch", 12)),
			win(2, "notes", false, active(agent("pi", "release notes draft", state.StateIdle, 2*86400, 260))),
			win(3, "build", true, focused(600, active(shell("zsh", "", 8)))),
			win(4, "remote-worker", false, active(remote())),
		),
		sess("$5", "dotfiles-agents-with-a-very-long-session-name-for-truncation", now-120,
			win(1, "main", true, active(agent("claude", "docs sweep", state.StateWorking, 300, 700))),
		),
		sess("$6", "dotfiles", now,
			win(1, "picker", true,
				active(agent("claude", "agent picker ui", state.StateWorking, 15, 820)),
				shell("zsh", "go test ./ui/", 10)),
			win(2, "nvim", false, active(shell("nvim", "nvim picker/ui/render.go", 240))),
		),
	}
	ss[5].Current = true
	return &state.Snapshot{CurrentID: "$6", Sessions: ss, Now: now}
}

// fakeActions records calls and returns next on Load.
type fakeActions struct {
	next    *state.Snapshot
	calls   []string
	err     error // returned by every action
	loadErr error
	loads   int
}

var errFake = errors.New("boom")

func (f *fakeActions) Load() (*state.Snapshot, error) {
	f.loads++
	if f.loadErr != nil {
		return nil, f.loadErr
	}
	if f.next != nil {
		return f.next, nil
	}
	return fixture(), nil
}

func (f *fakeActions) rec(format string, args ...any) error {
	f.calls = append(f.calls, fmt.Sprintf(format, args...))
	return f.err
}

func (f *fakeActions) Switch(s *state.Session, w *state.Window, p *state.Pane) error {
	wid, pid := "-", "-"
	if w != nil {
		wid = w.ID
	}
	if p != nil {
		pid = p.ID
	}
	return f.rec("switch %s %s %s", s.ID, wid, pid)
}
func (f *fakeActions) CreateSession(name string) error { return f.rec("create %s", name) }
func (f *fakeActions) NewSession(name, dir string) error {
	return f.rec("new-session %s%s", name, dirArg(dir))
}
func (f *fakeActions) NewWindow(s *state.Session, dir, name string) error {
	return f.rec("new-window %s %q%s", s.ID, name, dirArg(dir))
}
func (f *fakeActions) RenameWindow(w *state.Window, name string) error {
	return f.rec("rename-window %s %s", w.ID, name)
}
func (f *fakeActions) RenameSession(s *state.Session, name string) error {
	return f.rec("rename-session %s %s", s.ID, name)
}
func (f *fakeActions) KillPane(p *state.Pane) error       { return f.rec("kill-pane %s", p.ID) }
func (f *fakeActions) KillWindow(w *state.Window) error   { return f.rec("kill-window %s", w.ID) }
func (f *fakeActions) KillSession(s *state.Session) error { return f.rec("kill-session %s", s.ID) }

// dirArg is " -c DIR" for a start directory, nothing for the default.
func dirArg(dir string) string {
	if dir == "" {
		return ""
	}
	return " -c " + dir
}
