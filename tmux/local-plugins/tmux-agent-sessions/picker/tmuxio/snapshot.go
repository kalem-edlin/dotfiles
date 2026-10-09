// Package tmuxio is the picker's tmux side: one snapshot read (one tmux call,
// one pane-mem call) and the actions that used to live in scripts/action.
// See docs/notes/tmux-agent-sessions.md, "Picker".
package tmuxio

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"agentpicker/state"
	"agentpicker/worktree"
)

// sep is U+241E. tmux may rewrite control characters in format values, and
// session or window names may contain almost anything else, so fields are
// joined with a printable character nobody types (as in v1).
const sep = "␞"

// fields is the list-panes format, in column order. The first 19 are v1's.
// The two paths are kept raw (no clean) and sit before numeric last
// columns, so a path with a line break in it is joined back up by
// parseRows like a multi-line command line is.
var fields = []string{
	"#{session_id}",
	"#{session_name}",
	"#{session_last_attached}",
	"#{window_id}",
	"#{window_index}",
	"#{window_name}",
	"#{window_active}",
	"#{pane_id}",
	"#{pane_index}",
	"#{pane_active}",
	"#{pane_pid}",
	"#{pane_current_command}",
	"#{@remote-host}",
	"#{@agent_kind}",
	"#{@agent_state}",
	"#{@agent_name}",
	"#{@agent_at}",
	"#{@agent_pid}",
	"#{@agent_subs}",
	"#{@workspace-last-command}",
	"#{@agent_state_at}",
	"#{@agent_empty}",
	"#{pane_current_path}",
	"#{@agent_cwd}",
	"#{@pane_focus_at}",
	"#{session_attached}",
}

// Column indexes into a row.
const (
	fSessionID = iota
	fSessionName
	fLastAttached
	fWindowID
	fWindowIndex
	fWindowName
	fWindowActive
	fPaneID
	fPaneIndex
	fPaneActive
	fPanePID
	fCommand
	fRemoteHost
	fAgentKind
	fAgentState
	fAgentName
	fAgentAt
	fAgentPID
	fAgentSubs
	fLastCommand
	fStateAt
	fAgentEmpty
	fPath
	fAgentCwd
	fFocusAt
	fAttached
	nFields
)

var listFormat = strings.Join(fields, sep)

// clientFormat is the client's line ahead of the panes: its session id and
// its active pane id.
const clientFormat = "#{session_id}" + sep + "#{pane_id}"

// paneMemPath is scripts/pane-mem. Empty means "locate it next to the
// binary"; tests point it at a fake.
var paneMemPath = ""

// Load reads one snapshot: one tmux call, then one pane-mem call.
func (a *actions) Load() (*state.Snapshot, error) {
	var args []string
	if a.client != "" {
		args = append(args, "display-message", "-p", "-c", a.client, clientFormat, ";")
	}
	args = append(args, "list-panes", "-a", "-F", listFormat)
	out, err := runTmux(args...)
	if err != nil {
		return nil, err
	}
	// Without a client there is no client line; keep the shape the
	// parser expects (an empty first line), like v1.
	if a.client == "" {
		out = "\n" + out
	}
	cl, rows := parseRows(out)

	mem, err := readMem(memPIDs(rows))
	if err != nil {
		return nil, err
	}
	return buildSnapshot(cl, rows, mem, time.Now().Unix()), nil
}

// parseSnapshot is parseRows plus buildSnapshot, for tests.
func parseSnapshot(raw string, mem map[int]int64, now int64) *state.Snapshot {
	cl, rows := parseRows(raw)
	return buildSnapshot(cl, rows, mem, now)
}

// clientLine is the invoking client's first line: its session id and active
// pane id, both "" when unknown.
type clientLine struct{ session, pane string }

// parseRows splits raw tmux output: the first line is the client's session
// id and active pane id (possibly empty), every following record is one
// pane of nFields fields. A value with a raw newline in it (a multi-line
// @workspace-last-command, say) spreads a record over several lines, so
// lines are joined until the record has all its separators.
func parseRows(raw string) (clientLine, [][]string) {
	first, rest, _ := strings.Cut(raw, "\n")
	sid, pid, _ := strings.Cut(first, sep)
	cl := clientLine{session: strings.TrimSpace(sid), pane: strings.TrimSpace(pid)}

	var rows [][]string
	var acc string
	pending := false
	flush := func() {
		f := strings.Split(acc, sep)
		for len(f) < nFields {
			f = append(f, "")
		}
		if f[fSessionID] != "" && f[fPaneID] != "" {
			rows = append(rows, f)
		}
		acc, pending = "", false
	}
	for _, line := range strings.Split(rest, "\n") {
		if pending {
			acc += "\n" + line
		} else {
			if line == "" {
				continue
			}
			acc, pending = line, true
		}
		if strings.Count(acc, sep) >= nFields-1 {
			flush()
		}
	}
	if pending {
		flush()
	}
	return cl, rows
}

// memPIDs is every pane pid and every non-empty @agent_pid, for pane-mem.
func memPIDs(rows [][]string) []string {
	var pids []string
	for _, f := range rows {
		pids = append(pids, f[fPanePID])
		if f[fAgentPID] != "" {
			pids = append(pids, f[fAgentPID])
		}
	}
	return pids
}

// readMem runs pane-mem once. Its output is "PID KIB" per live root; a pid
// missing from it is not alive.
func readMem(pids []string) (map[int]int64, error) {
	mem := map[int]int64{}
	if len(pids) == 0 {
		return mem, nil
	}
	path := paneMemPath
	if path == "" {
		p, err := locatePaneMem()
		if err != nil {
			return nil, err
		}
		path = p
	}
	var stdout bytes.Buffer
	cmd := exec.Command(path, pids...)
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		// pane-mem always exits 0; a non-zero exit still leaves whatever
		// it printed usable. Only a failure to start is an error.
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			return nil, fmt.Errorf("pane-mem: %v", err)
		}
	}
	return parseMem(stdout.String()), nil
}

func parseMem(out string) map[int]int64 {
	mem := map[int]int64{}
	for _, line := range strings.Split(out, "\n") {
		f := strings.Fields(line)
		if len(f) != 2 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		kib, err2 := strconv.ParseInt(f[1], 10, 64)
		if err1 == nil && err2 == nil {
			mem[pid] = kib
		}
	}
	return mem
}

// locatePaneMem finds scripts/pane-mem from the binary, which lives at
// PLUGIN/bin/agent-picker. Resolve symlinks first: stow may link the binary.
func locatePaneMem() (string, error) {
	exe, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("pane-mem: locate binary: %v", err)
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	plugin := filepath.Dir(filepath.Dir(exe))
	return filepath.Join(plugin, "scripts", "pane-mem"), nil
}

// buildSnapshot turns rows into the session tree and groups the panes into
// worktrees. Rules from v1: an agent whose @agent_pid is not alive is no
// agent; remote panes get no memory and no agent; an unknown agent state
// reads as idle.
func buildSnapshot(cl clientLine, rows [][]string, mem map[int]int64, now int64) *state.Snapshot {
	current := cl.session
	snap := &state.Snapshot{CurrentID: current, CurrentPane: cl.pane, Now: now}
	sessions := map[string]*state.Session{}
	windows := map[string]*state.Window{}

	for _, f := range rows {
		s := sessions[f[fSessionID]]
		if s == nil {
			s = &state.Session{
				ID:           f[fSessionID],
				Name:         clean(f[fSessionName]),
				LastAttached: atoi64(f[fLastAttached]),
				Attached:     atoi(f[fAttached]) > 0,
				Current:      current != "" && f[fSessionID] == current,
			}
			sessions[s.ID] = s
			snap.Sessions = append(snap.Sessions, s)
		}
		// Window ids are unique per server, but a window linked into two
		// sessions has one id in both, so key by session too.
		wkey := s.ID + " " + f[fWindowID]
		w := windows[wkey]
		if w == nil {
			w = &state.Window{
				ID:      f[fWindowID],
				Index:   atoi(f[fWindowIndex]),
				Name:    clean(f[fWindowName]),
				Active:  f[fWindowActive] == "1",
				Session: s,
			}
			windows[wkey] = w
			s.Windows = append(s.Windows, w)
		}
		w.Panes = append(w.Panes, buildPane(f, mem, w))
	}

	for _, s := range snap.Sessions {
		sort.SliceStable(s.Windows, func(i, j int) bool { return s.Windows[i].Index < s.Windows[j].Index })
		for _, w := range s.Windows {
			sort.SliceStable(w.Panes, func(i, j int) bool { return w.Panes[i].Index < w.Panes[j].Index })
		}
	}
	// Worktrees are grouped in tmux's session order, before the sort, so
	// their windows and full ties do not depend on agent states.
	snap.Worktrees = buildWorktrees(snap.Sessions, cl.pane, worktree.NewResolver().Resolve)
	sortRows(snap.Sessions)
	sortRows(snap.Worktrees)
	return snap
}

// buildWorktrees groups panes by the worktree holding their effective
// directory, resolving each directory once (one resolver per load). Every
// pane's Worktree is set, nil outside a repository. A window linked into
// several sessions counts once, under the first session that has it.
// currentPane's worktree is the current one. The result is in first
// appearance order, unsorted.
func buildWorktrees(sessions []*state.Session, currentPane string, resolve func(dir string) (worktree.Info, bool)) []*state.Worktree {
	var out []*state.Worktree
	byRoot := map[string]*state.Worktree{}
	seen := map[string]bool{} // window ids already grouped
	for _, s := range sessions {
		for _, w := range s.Windows {
			first := !seen[w.ID]
			seen[w.ID] = true
			for _, p := range w.Panes {
				info, ok := resolve(p.Dir())
				if !ok {
					continue
				}
				t := byRoot[info.Root]
				if t == nil {
					t = &state.Worktree{Root: info.Root, Repo: info.Repo, Branch: info.Branch, Head: info.Head}
					byRoot[info.Root] = t
					out = append(out, t)
				}
				p.Worktree = t
				if currentPane != "" && p.ID == currentPane {
					t.Current = true
				}
				if !first {
					continue
				}
				if n := len(t.Windows); n == 0 || t.Windows[n-1] != w {
					t.Windows = append(t.Windows, w)
				}
				t.Panes = append(t.Panes, p)
			}
		}
	}
	return out
}

// sortRows orders rows for display.
func sortRows[R state.Row](rows []R) {
	// Top to bottom, so the highest priority sits nearest the cursor at
	// the bottom: the client's own row last, the others by awaiting
	// agents, then done, then working, then the newest agent state change,
	// then recency (a session's latest attach, a worktree's latest focus),
	// each higher value lower. Stable, so full ties keep tmux's order.
	type rank struct {
		awaiting, done, working int
		at, recent              int64
	}
	ranks := make(map[string]rank, len(rows))
	for _, r := range rows {
		k := rank{recent: r.Recency()}
		k.awaiting, k.done, k.working, k.at = state.AgentCounts(r.Members())
		ranks[r.RowID()] = k
	}
	sort.SliceStable(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.IsCurrent() != b.IsCurrent() {
			return b.IsCurrent()
		}
		x, y := ranks[a.RowID()], ranks[b.RowID()]
		switch {
		case x.awaiting != y.awaiting:
			return x.awaiting < y.awaiting
		case x.done != y.done:
			return x.done < y.done
		case x.working != y.working:
			return x.working < y.working
		case x.at != y.at:
			return x.at < y.at
		}
		return x.recent < y.recent
	})
}

func buildPane(f []string, mem map[int]int64, w *state.Window) *state.Pane {
	p := &state.Pane{
		ID:          f[fPaneID],
		Index:       atoi(f[fPaneIndex]),
		Active:      f[fPaneActive] == "1",
		PID:         atoi(f[fPanePID]),
		Command:     clean(f[fCommand]),
		LastCommand: clean(f[fLastCommand]),
		Remote:      f[fRemoteHost] != "",
		Path:        f[fPath],
		AgentCwd:    f[fAgentCwd],
		FocusAt:     atoi64(f[fFocusAt]),
		Window:      w,
	}
	if !p.Remote {
		p.MemKB, p.HasMem = mem[p.PID]
	}

	kind := f[fAgentKind]
	if kind != "" && f[fAgentPID] != "" {
		pid, err := strconv.Atoi(f[fAgentPID])
		if _, alive := mem[pid]; err != nil || !alive {
			kind = "" // died without clearing its options
		}
	}
	if p.Remote || kind == "" {
		return p
	}
	p.AgentKind = kind
	p.AgentName = clean(f[fAgentName])
	p.AgentEmpty = f[fAgentEmpty] == "1"
	p.AgentAt = atoi64(f[fAgentAt])
	p.StateAt = atoi64(f[fStateAt])
	p.Subs = f[fAgentSubs]
	switch st := state.State(f[fAgentState]); st {
	case state.StateAwaiting, state.StateDone, state.StateWorking:
		p.State = st
	default:
		p.State = state.StateIdle
	}
	return p
}

// clean replaces tabs and line breaks with spaces so a name cannot break a
// rendered row.
func clean(s string) string {
	if !strings.ContainsAny(s, "\t\r\n") {
		return s
	}
	return strings.NewReplacer("\t", " ", "\r", " ", "\n", " ").Replace(s)
}

func atoi(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}

func atoi64(s string) int64 {
	n, _ := strconv.ParseInt(s, 10, 64)
	return n
}
