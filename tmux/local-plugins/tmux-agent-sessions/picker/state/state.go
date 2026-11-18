// Package state holds the data the picker works on: one snapshot of the
// tmux server, and the interface for the picker's tmux side effects. The
// tmuxio package fills it, the main package renders it. See
// docs/notes/tmux-agent-sessions.md, "Picker".
package state

import "strings"

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
	// Remote: @remote-host is set (D3), or @rw-root-id names a root an rw
	// ownership record says a worker holds (D10). Remote panes have no
	// memory and no agent.
	Remote   bool
	RootID   string // @rw-root-id, the rw root the pane was handed off or opened in
	MemKB    int64  // pane-mem footprint of the pane's process tree
	HasMem   bool   // false for remote panes and when pane-mem gave no value
	Path     string // #{pane_current_path}
	AgentCwd string // @agent_cwd, the agent's own working directory as its hooks last reported it
	FocusAt  int64  // @pane_focus_at, epoch seconds the pane last gained focus, 0 if unset
	// Worktree is the worktree whose session holds the pane, nil when the
	// session is named after no worktree.
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

// Row is one list row: a worktree, or a session no worktree has. Both
// order, aggregate and pick their default card from their member panes.
type Row interface {
	// RowID identifies the row across reloads: the session id, or the
	// worktree root.
	RowID() string
	// Members are the panes the row's chips and agents count.
	Members() []*Pane
	// IsCurrent reports the invoking client's own row, listed last.
	IsCurrent() bool
	// Recency is the row's last access, its only ordering key.
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

// HasRemote reports whether any pane of the window is remote: its card
// shows `remote` in a mixed session (D10).
func (w *Window) HasRemote() bool {
	for _, p := range w.Panes {
		if p.Remote {
			return true
		}
	}
	return false
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

// Recency is the session's last activity: the newest of its last attach,
// its panes' @pane_focus_at and its agents' state changes (StateSince).
// Agent events count because a session restored from a snapshot has no
// attach and no focus stamps until it is visited, yet its agents keep
// working and finishing (D95).
func (s *Session) Recency() int64 {
	at := s.LastAttached
	for _, w := range s.Windows {
		for _, p := range w.Panes {
			at = max(at, p.FocusAt, p.StateSince())
		}
	}
	return at
}

// AllRemote reports whether every pane of the session is remote, so the
// whole row shows `remote` (D10). A session without panes is not.
func (s *Session) AllRemote() bool {
	n := 0
	for _, w := range s.Windows {
		for _, p := range w.Panes {
			if !p.Remote {
				return false
			}
			n++
		}
	}
	return n > 0
}

// Members is every pane of the session, in window and pane order.
func (s *Session) Members() []*Pane {
	var out []*Pane
	for _, w := range s.Windows {
		out = append(out, w.Panes...)
	}
	return out
}

// Worktree is one git worktree found under the discovery root (V5),
// whether or not a session has it. A session has it when the session's
// name is the worktree directory's basename (V1, SessionName); its windows
// and panes are then the worktree's, and pane directories play no part.
type Worktree struct {
	Root     string // worktree root directory, the row's id
	Name     string // basename of Root
	Repo     string // source repo directory name
	Branch   string // "" when HEAD is detached
	Head     string // 7-char commit id when detached
	Main     bool   // the repo's main checkout
	Locked   bool   // git worktree lock
	Missing  bool   // the directory is gone (prunable)
	ActiveAt int64  // newest mtime of its HEAD and index, the last-active key without a session
	// Remote: an rw ownership record says a worker holds Root (D10, P1).
	// The row shows `remote` with or without a session, and new windows
	// for it open on the worker.
	Remote  bool
	Current bool // its session is the invoking client's
	// Session is the session named after the worktree, nil for none: the
	// row is then dim and has no cards.
	Session *Session
	Windows []*Window // Session's windows
	Panes   []*Pane   // every pane of Session, in window and pane order
}

func (t *Worktree) RowID() string    { return t.Root }
func (t *Worktree) IsCurrent() bool  { return t.Current }
func (t *Worktree) Members() []*Pane { return t.Panes }
func (t *Worktree) Detached() bool   { return t.Branch == "" }

// AllRemote is the row-level `remote` fact (D10): the root is held by a
// worker, or every pane of its session is remote.
func (t *Worktree) AllRemote() bool {
	return t.Remote || (t.Session != nil && t.Session.AllRemote())
}

// Recency is the worktree's last activity: its session's last access
// (newest focus stamp or attach), else the newest mtime of its HEAD and
// index (V5).
func (t *Worktree) Recency() int64 {
	if t.Session != nil {
		if at := t.Session.Recency(); at != 0 {
			return at
		}
	}
	return t.ActiveAt
}

// SessionName is the session name a worktree's session has: the
// directory's basename with the characters tmux rewrites in session names
// ('.' and ':') turned into '_', as tmux itself does.
func SessionName(base string) string {
	return strings.NewReplacer(".", "_", ":", "_").Replace(base)
}

// ListRows merges worktrees and the sessions no worktree has into one list
// (V3, V5). Both inputs are in display order already (sorted by last
// access, the current row last); the merge keeps each one's order and
// interleaves them by Recency, a worktree first on a tie. The current row
// stays last.
func ListRows(worktrees []*Worktree, sessions []*Session) []Row {
	owned := map[*Session]bool{}
	for _, t := range worktrees {
		if t.Session != nil {
			owned[t.Session] = true
		}
	}
	var plain []*Session
	for _, s := range sessions {
		if !owned[s] {
			plain = append(plain, s)
		}
	}
	out := make([]Row, 0, len(worktrees)+len(plain))
	i, j := 0, 0
	for i < len(worktrees) || j < len(plain) {
		switch {
		case j == len(plain):
			out = append(out, worktrees[i])
			i++
		case i == len(worktrees):
			out = append(out, plain[j])
			j++
		case rowBefore(plain[j], worktrees[i]):
			out = append(out, plain[j])
			j++
		default:
			out = append(out, worktrees[i])
			i++
		}
	}
	return out
}

// rowBefore is the display order: the current row last, the rest by last
// access, oldest first.
func rowBefore(a, b Row) bool {
	if a.IsCurrent() != b.IsCurrent() {
		return b.IsCurrent()
	}
	return a.Recency() < b.Recency()
}

// Snapshot is one read of the server: one tmux call and one pane-mem call.
type Snapshot struct {
	CurrentID   string // session id of the invoking client, "" if unknown
	CurrentPane string // id of the invoking client's active pane, "" if unknown
	// Sessions in display order, top to bottom, the most recently accessed
	// lowest: see the sort in tmuxio. The client's own session is last (D9,
	// D17).
	Sessions []*Session
	// Worktrees is every discovered worktree in display order, sorted as
	// Sessions are, the current session's worktree last.
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
	// CreateSession creates a session named name starting in dir (the home
	// directory when empty) and switches the client to it: enter with an
	// unmatched query, or on a worktree row without a session. The picker
	// exits after it.
	CreateSession(name, dir string) error
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

	// Worktree lifecycle (B3) runs the `wt` script with --json. An error
	// from a non-zero exit is a *WTError carrying wt's exit code. new,
	// repurpose and remove make the next Load rescan the worktrees.
	//
	// WorktreeNew creates a worktree of the repo that root belongs to, on
	// branch, cut from from (wt's default base, origin/main or main, when
	// empty). Nothing is installed.
	WorktreeNew(root, branch, from string) (WTResult, error)
	// WorktreeStatus reads the worktree's state for the delete
	// refusals (linked worktrees of a main checkout, a lock's reason).
	WorktreeStatus(root string) (WTStatus, error)
	// WorktreeRepurpose switches the worktree in place to branch, cut
	// from wt's default base, stashing a dirty tree first (--stash,
	// D105).
	WorktreeRepurpose(root, branch string) (WTResult, error)
	// WorktreeRemove moves the worktree to the Trash, dirt and all, and
	// prunes its registration (never its branch, D105). A main checkout
	// with no linked worktrees moves there too; a missing directory's
	// registration is pruned (D102). A locked worktree is refused. wt rm
	// itself runs rw forget for the workers holding root (D11) and refuses
	// a root that is remote right now unless discardRemote (wt rm
	// --discard-remote): the user confirmed losing the only current copy.
	WorktreeRemove(root string, discardRemote bool) (WTResult, error)
	// WorktreeEnvRefresh pulls the env renders afresh in the main checkout
	// of root's repo (its `wt.envPull` git config, when set) and copies
	// them to every linked worktree, each keeping its own ports (D109).
	// With here the worktree at root is the source instead, copied as it
	// is to every other worktree, main included, and nothing is pulled.
	WorktreeEnvRefresh(root string, here bool) (WTEnvResult, error)
	// SaveLayout starts a verified resurrect save in the background,
	// detached, and does not wait for it.
	SaveLayout() error

	// ForgetRoot runs `rw forget <root> --worker <alias>` for every worker
	// that holds a copy of root, as rw's records say (D11): the worker
	// copies and their remote sessions go before the root is deleted
	// here. Nothing runs when no worker holds it. An unreachable worker
	// (rw exit 6) is no error: rw keeps a pending forget for the next
	// contact, and the worker is listed in Pending. Any other failure is
	// an error and the delete must stop.
	ForgetRoot(root string) (RWForget, error)
}

// RWForget is what ForgetRoot did. Workers are never named in the UI (D10);
// the counts are.
type RWForget struct {
	Forgotten []string // workers whose copy was deleted
	Pending   []string // unreachable workers, deleted on next contact
	NoRW      bool     // workers hold the root but rw is not installed
}

// wt exit codes (git/.local/bin/wt).
const (
	WTUsage   = 2
	WTDirty   = 3
	WTLocked  = 4
	WTRefused = 5
	WTPorts   = 6
)

// WTError is a failed wt call: its exit code and its message (the JSON
// "error" field, else the first line of stderr).
type WTError struct {
	Op   string // "new", "status", "rm", "repurpose" or "env-refresh"
	Code int    // wt's exit code, -1 when it did not run or timed out
	Msg  string
}

func (e *WTError) Error() string { return "wt " + e.Op + ": " + e.Msg }

// WTStatus is `wt status --json`. Null fields read as zero values.
type WTStatus struct {
	Path       string   `json:"path"`
	Main       bool     `json:"main"`
	Branch     string   `json:"branch"` // "" when detached
	Head       string   `json:"head"`
	Dirty      int      `json:"dirty"`
	Untracked  int      `json:"untracked"`
	Upstream   string   `json:"upstream"` // "" without one
	Ahead      int      `json:"ahead"`
	Behind     int      `json:"behind"`
	Merged     bool     `json:"merged"`
	Locked     bool     `json:"locked"`
	LockReason string   `json:"lock_reason"`
	Heavy      []string `json:"heavy"`
	Linked     int      `json:"linked"` // main only: registered linked worktrees, prunable included
}

// WTResult is the JSON of `wt new`, `wt repurpose` and `wt rm`; each sets
// the fields it reports.
type WTResult struct {
	Path           string `json:"path"`       // new, repurpose: the worktree root
	Removed        string `json:"removed"`    // rm: the removed root
	Pruned         string `json:"pruned"`     // rm of a missing worktree: the pruned root
	Main           bool   `json:"main"`       // rm: a whole repo (main checkout) went to the Trash
	TrashedTo      string `json:"trashed_to"` // rm: where it went in the Trash
	Branch         string `json:"branch"`
	PreviousBranch string `json:"previous_branch"` // repurpose
	Stashed        bool   `json:"stashed"`         // repurpose --stash stashed a dirty tree
	Stash          string `json:"stash"`           // the stash's short id
	StashedChanges int    `json:"stashed_changes"` // repurpose: changed plus untracked files stashed
	NeedsInstall   bool   `json:"needs_install"`   // repurpose: pnpm-lock.yaml changed
	NeedsPods      bool   `json:"needs_pods"`      // repurpose: app.config or a Podfile changed
}

// WTEnvResult is `wt env-refresh --json` (D109).
type WTEnvResult struct {
	Main      string          `json:"main"`      // the main checkout
	Source    string          `json:"source"`    // the worktree copied from: main, or root with here
	Pulled    bool            `json:"pulled"`    // wt.envPull ran there first
	Files     []string        `json:"files"`     // the env files copied (gitignored .env* at main minus the deny list)
	Refreshed int             `json:"refreshed"` // linked worktrees written
	Missing   []string        `json:"missing"`   // registered worktrees whose directory is gone, skipped
	Worktrees []WTEnvWorktree `json:"worktrees"`
}

// WTEnvWorktree is one refreshed worktree.
type WTEnvWorktree struct {
	Path      string   `json:"path"`
	Copied    []string `json:"copied"`
	Rewritten []string `json:"rewritten"` // .env.local keys rewritten for its port block
	Skipped   []string `json:"skipped"`   // symlinked targets left alone
}
