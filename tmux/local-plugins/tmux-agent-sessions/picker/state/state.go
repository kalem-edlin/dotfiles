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
	// Worktree holds Dir(), nil when Dir() is in no git repository.
	Worktree *Worktree

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

// AgentCounts counts the live agents in panes by state and finds the
// newest state change among all of them (0 when none). An agent in any
// other state counts as idle, and remote panes have no agent, as on the
// list rows.
func AgentCounts(panes []*Pane) (awaiting, done, working int, at int64) {
	for _, p := range panes {
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
	return
}

// Row is one list row: a session, or a worktree in worktree mode. Both
// order, aggregate and pick their default card from their member panes.
type Row interface {
	// RowID identifies the row across reloads: the session id, or the
	// worktree root.
	RowID() string
	// Members are the panes the row's chips and agents count.
	Members() []*Pane
	// IsCurrent reports the invoking client's own row, listed last.
	IsCurrent() bool
	// Recency is the last ordering key, after the agent counts.
	Recency() int64
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
	Attached     bool  // #{session_attached}: at least one client shows it
	Current      bool  // the invoking client's session
	Windows      []*Window
}

func (s *Session) RowID() string   { return s.ID }
func (s *Session) IsCurrent() bool { return s.Current }
func (s *Session) Recency() int64  { return s.LastAttached }

// Members is every pane of the session, in window and pane order.
func (s *Session) Members() []*Pane {
	var out []*Pane
	for _, w := range s.Windows {
		out = append(out, w.Panes...)
	}
	return out
}

// Worktree is one git worktree holding the effective directory (Pane.Dir)
// of at least one pane. Panes outside every repository belong to none.
type Worktree struct {
	Root    string // worktree root directory, the row's id
	Repo    string // source repo directory name
	Branch  string // "" when HEAD is detached
	Head    string // 7-char commit id when detached
	Current bool   // holds the invoking client's active pane
	// Windows that hold at least one member pane, each once: a window
	// linked into several sessions is kept under the first of them.
	Windows []*Window
	Panes   []*Pane // member panes of Windows, in window and pane order
}

func (t *Worktree) RowID() string    { return t.Root }
func (t *Worktree) IsCurrent() bool  { return t.Current }
func (t *Worktree) Members() []*Pane { return t.Panes }
func (t *Worktree) Detached() bool   { return t.Branch == "" }

// Recency is the newest @pane_focus_at among the member panes.
func (t *Worktree) Recency() int64 {
	var at int64
	for _, p := range t.Panes {
		at = max(at, p.FocusAt)
	}
	return at
}

// Snapshot is one read of the server: one tmux call and one pane-mem call.
type Snapshot struct {
	CurrentID   string // session id of the invoking client, "" if unknown
	CurrentPane string // id of the invoking client's active pane, "" if unknown
	// Sessions in display order, top to bottom, higher priority lower: see
	// the sort in tmuxio. The client's own session is last (D9, D17).
	Sessions []*Session
	// Worktrees in display order, sorted as Sessions are, the worktree of
	// CurrentPane last.
	Worktrees []*Worktree
	Now       int64 // epoch seconds when the snapshot was read, for ages
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
	// NewSession creates a detached session (C-a C) starting in dir, or in
	// the home directory when dir is empty. The picker stays open.
	NewSession(name, dir string) error
	// NewWindow creates a window in s without switching (C-a c), starting
	// in dir, or in the directory of s's active pane when dir is empty. An
	// empty name keeps automatic naming.
	NewWindow(s *Session, dir, name string) error
	RenameWindow(w *Window, name string) error
	RenameSession(s *Session, name string) error
	// Kill paths close remote panes through rw-close.sh --pane first.
	KillPane(p *Pane) error
	KillWindow(w *Window) error
	KillSession(s *Session) error
}
