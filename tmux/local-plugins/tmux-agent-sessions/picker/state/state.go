// Package state holds the data the picker works on: one snapshot of the
// tmux server, and the interface for the picker's tmux side effects. The
// tmuxio package fills it, the main package renders it. See
// docs/notes/tmux-agent-sessions.md, "Picker".
package state

// State is a pane's agent state as the picker shows it. StateNone means
// the pane has no live agent.
type State string

const (
	StateNone     State = ""
	StateAwaiting State = "awaiting"
	StateDone     State = "finished" // shown as "Done" in the UI (D19)
	StateWorking  State = "working"
	StateIdle     State = "idle"
)

// StateOrder is the order of aggregated status chips (D21).
var StateOrder = []State{StateAwaiting, StateDone, StateWorking, StateIdle}

// Pane is one tmux pane.
type Pane struct {
	ID          string // "%12"
	Index       int
	Active      bool
	PID         int
	Command     string // #{pane_current_command}
	LastCommand string // @workspace-last-command, the last shell command line
	Remote      bool   // @remote-host is set (D3). Remote panes have no memory and no agent.
	MemKB       int64  // pane-mem footprint of the pane's process tree
	HasMem      bool   // false for remote panes and when pane-mem gave no value
	Path        string // #{pane_current_path}
	AgentCwd    string // @agent_cwd, the agent's own working directory as its hooks last reported it
	FocusAt     int64  // @pane_focus_at, epoch seconds the pane last gained focus, 0 if unset

	// Agent fields are zero unless a live agent publishes into the pane.
	// An agent whose @agent_pid is gone counts as no agent.
	AgentKind  string // @agent_kind: "claude" or "pi"
	AgentName  string // @agent_name
	AgentEmpty bool   // @agent_empty is 1: the chat has no messages yet (D59)
	State      State  // StateNone without an agent, otherwise one of StateOrder
	AgentAt    int64  // @agent_at, epoch seconds of the last agent event (D15)
	StateAt    int64  // @agent_state_at, epoch seconds the state began (D29), 0 if unset
	Subs       string // @agent_subs

	Window *Window
}

// StateSince is when the pane's state began: @agent_state_at, else
// @agent_at.
func (p *Pane) StateSince() int64 {
	if p.StateAt != 0 {
		return p.StateAt
	}
	return p.AgentAt
}

// Dir is the pane's effective directory: a live agent's @agent_cwd when it
// published one, since an agent can move away from where its pane started,
// else #{pane_current_path}.
func (p *Pane) Dir() string {
	if p.State != StateNone && p.AgentCwd != "" {
		return p.AgentCwd
	}
	return p.Path
}

// AgentCounts counts the session's live agents by state and finds the
// newest state change among all of them (0 when none). An agent in any
// other state counts as idle, and remote panes have no agent, as on the
// session rows.
func (s *Session) AgentCounts() (awaiting, done, working int, at int64) {
	for _, w := range s.Windows {
		for _, p := range w.Panes {
			if p.Remote || p.State == StateNone {
				continue
			}
			switch p.State {
			case StateAwaiting:
				awaiting++
			case StateDone:
				done++
			case StateWorking:
				working++
			}
			at = max(at, p.StateSince())
		}
	}
	return
}

// Window is one tmux window. Panes are in ascending pane index.
type Window struct {
	ID      string // "@3"
	Index   int
	Name    string
	Active  bool
	Panes   []*Pane
	Session *Session
}

// Session is one tmux session. Windows are in ascending window index.
type Session struct {
	ID           string // "$1"
	Name         string
	LastAttached int64 // #{session_last_attached}, 0 if never attached
	Current      bool  // the invoking client's session
	Windows      []*Window
}

// Snapshot is one read of the server: one tmux call and one pane-mem call.
type Snapshot struct {
	CurrentID   string // session id of the invoking client, "" if unknown
	CurrentPane string // id of the invoking client's active pane, "" if unknown
	// Sessions in display order, top to bottom, higher priority lower: see
	// the sort in tmuxio. The client's own session is last (D9, D17).
	Sessions []*Session
	Now      int64 // epoch seconds when the snapshot was read, for ages
}

// Actions performs the picker's tmux side effects. The model calls it
// through this interface so model tests can use a fake. Each method
// returns an error whose message is shown inline in the picker.
type Actions interface {
	// Load reads a fresh snapshot.
	Load() (*Snapshot, error)
	// Switch moves the invoking client to the window w of session s, and
	// selects pane p when p is not nil (a split card). w may be nil for a
	// session without windows. The picker exits after it.
	Switch(s *Session, w *Window, p *Pane) error
	// CreateSession creates a session named name and switches the client
	// to it (enter with an unmatched query). The picker exits after it.
	CreateSession(name string) error
	// NewSession creates a detached session (C-a C). The picker stays open.
	NewSession(name string) error
	// NewWindow creates a window in s, in the directory of s's active pane,
	// without switching (C-a c). An empty name keeps automatic naming.
	NewWindow(s *Session, name string) error
	RenameWindow(w *Window, name string) error
	RenameSession(s *Session, name string) error
	// Kill paths close remote panes through rw-close.sh --pane first.
	KillPane(p *Pane) error
	KillWindow(w *Window) error
	KillSession(s *Session) error
}
