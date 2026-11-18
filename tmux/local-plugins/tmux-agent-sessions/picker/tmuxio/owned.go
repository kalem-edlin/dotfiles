package tmuxio

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// Remote-owned roots (docs/tasks/mini-remote-sessions.md, P1, D10, D11):
// tmux-remote-workspaces keeps one ownership record per handed-off
// directory root at <state dir>/owned/<root_id>/record.json (contract C1).
// The picker reads them as plain files: one directory read per snapshot,
// no process, no ssh, so the open budget holds. Deleting a root's worker
// copies (rw forget, D11) is wt rm's job, not the picker's.

// rwRecord is the part of record.json the picker uses.
type rwRecord struct {
	RootID    string `json:"root_id"`
	RootRel   string `json:"root_rel"`
	RootLocal string `json:"root_local"`
	Worker    string `json:"worker"`
	Owner     string `json:"owner"` // "focus" or "worker"
	Pending   *struct {
		Action string `json:"action"`
	} `json:"pending"`
}

// rwStateDir is rw's focus-side state dir, resolved as scripts/common.sh's
// rw_state_dir does: TMUX_REMOTE_WORKSPACES_STATE_DIR, else
// $XDG_STATE_HOME (or ~/.local/state)/tmux-remote-workspaces.
func rwStateDir() string {
	if d := os.Getenv("TMUX_REMOTE_WORKSPACES_STATE_DIR"); d != "" {
		return d
	}
	base := os.Getenv("XDG_STATE_HOME")
	if base == "" {
		base = filepath.Join(os.Getenv("HOME"), ".local/state")
	}
	return filepath.Join(base, "tmux-remote-workspaces")
}

// readRecords reads every owned/*/record.json; an unreadable one is
// skipped. No records (rw never used) is one failed ReadDir.
func readRecords() []rwRecord {
	dir := filepath.Join(rwStateDir(), "owned")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []rwRecord
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		b, err := os.ReadFile(filepath.Join(dir, e.Name(), "record.json"))
		if err != nil {
			continue
		}
		var r rwRecord
		if json.Unmarshal(b, &r) == nil && r.RootLocal != "" {
			out = append(out, r)
		}
	}
	return out
}

// ownership is the worker-owned roots of one read.
type ownership struct {
	byRoot map[string]rwRecord // root_local -> record
	byID   map[string]bool     // root_id
}

// readOwnership keeps the worker-owned records. A record with a pending
// forget is not remote any more: the root was deleted here and rw deletes
// the worker copy on its next contact.
func readOwnership() ownership {
	o := ownership{byRoot: map[string]rwRecord{}, byID: map[string]bool{}}
	for _, r := range readRecords() {
		if r.Owner != "worker" || (r.Pending != nil && r.Pending.Action == "forget") {
			continue
		}
		o.byRoot[filepath.Clean(r.RootLocal)] = r
		if r.RootID != "" {
			o.byID[r.RootID] = true
		}
	}
	return o
}

// rootFor is the worker-owned root holding dir (dir itself or its nearest
// ancestor, so the longest match wins, as rw_owned_root_for_path).
func (o ownership) rootFor(dir string) (rwRecord, bool) {
	if dir == "" || len(o.byRoot) == 0 {
		return rwRecord{}, false
	}
	for d := filepath.Clean(dir); ; {
		if r, ok := o.byRoot[d]; ok {
			return r, true
		}
		parent := filepath.Dir(d)
		if parent == d {
			return rwRecord{}, false
		}
		d = parent
	}
}

// rwTimeout bounds one rw call (preflight plus a remote session start).
var rwTimeout = 60 * time.Second

// rwBinary is rw's dispatcher: AGENT_SESSIONS_RW, else rw on PATH, else
// ~/.local/bin/rw, else the plugin's own scripts/rw; "" when none exists.
func rwBinary() string {
	if p := os.Getenv("AGENT_SESSIONS_RW"); p != "" {
		return p
	}
	if p, err := exec.LookPath("rw"); err == nil {
		return p
	}
	home := os.Getenv("HOME")
	for _, p := range []string{
		filepath.Join(home, ".local/bin/rw"),
		filepath.Join(home, ".config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw"),
	} {
		if isExecutable(p) {
			return p
		}
	}
	return ""
}

// runRW runs `rw ARGS...` with its output captured, stdin /dev/null (rw
// reaches ssh) and TMUX_PANE unset, so rw open always takes its --pane
// branch (respawn that pane) and never execs into the caller. code is rw's
// exit status, -1 when it did not run or timed out.
func runRW(rw string, args ...string) (out string, code int, err error) {
	ctx, cancel := context.WithTimeout(context.Background(), rwTimeout)
	defer cancel()
	var buf bytes.Buffer
	cmd := exec.CommandContext(ctx, rw, args...)
	cmd.Stdout, cmd.Stderr = &buf, &buf
	killGroupOnCancel(cmd)
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "TMUX_PANE=") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	err = cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return buf.String(), -1, fmt.Errorf("timed out after %s", rwTimeout)
	}
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return buf.String(), exitErr.ExitCode(), err
		}
		return buf.String(), -1, err
	}
	return buf.String(), 0, nil
}

// killGroupOnCancel runs cmd in its own process group and, when its
// context ends, kills the whole group, so an ssh child of rw or wt dies
// with it instead of holding the picker's pipes.
func killGroupOnCancel(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return nil
		}
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
	cmd.WaitDelay = time.Second
}

// rwDetail is rw's last "rw: " line (its refusal or failure; earlier lines
// are progress), without the prefix, else its last non-blank line.
func rwDetail(out string) string {
	var last, lastRW string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if l == "" {
			continue
		}
		last = l
		if strings.HasPrefix(l, "rw: ") {
			lastRW = strings.TrimPrefix(l, "rw: ")
		}
	}
	if lastRW != "" {
		return ": " + lastRW
	}
	if last != "" {
		return ": " + last
	}
	return ""
}

// remoteRootFor is the worker-owned root holding dir, read fresh: records
// change between the snapshot and an action.
func remoteRootFor(dir string) (rwRecord, bool) {
	return readOwnership().rootFor(dir)
}

// openRemote turns paneID, just created in rec's root, into a remote pane:
// `rw open --worker <alias> --root <root> --pane <id>` respawns it into the
// attach loop of a new worker session (no sync, contract C2). On failure
// the pane is killed (and with it a new window or session), so nobody is
// left typing into the frozen local copy (D17).
func openRemote(rw, paneID string, rec rwRecord) error {
	out, code, err := runRW(rw, "open", "--worker", rec.Worker, "--root", rec.RootLocal, "--pane", paneID)
	if err == nil {
		return nil
	}
	_, _ = runTmux("kill-pane", "-t", paneID)
	name := filepath.Base(rec.RootLocal)
	switch code {
	case 6:
		return fmt.Errorf("%s is remote and the remote is unreachable; nothing opened", name)
	case 7:
		return fmt.Errorf("rw open refused %s%s", name, rwDetail(out))
	case -1:
		return fmt.Errorf("rw open %s: %v", name, err)
	}
	return fmt.Errorf("rw open failed for %s%s", name, rwDetail(out))
}

// newPaneRemote runs a tmux command that creates one pane (new-window or
// new-session with -P -F '#{pane_id}') and opens it remote in rec's root.
// rw must exist before anything is created.
func newPaneRemote(rec rwRecord, args ...string) error {
	rw := rwBinary()
	if rw == "" {
		return fmt.Errorf("%s is remote, but rw is not installed; nothing opened", filepath.Base(rec.RootLocal))
	}
	out, err := runTmux(args...)
	if err != nil {
		return err
	}
	pane := strings.TrimSpace(out)
	if pane == "" {
		return errors.New("tmux did not report the new pane")
	}
	return openRemote(rw, pane, rec)
}

// RootRemote reports whether a worker owns the root holding dir right now,
// from a fresh read of the records. See state.Actions.
func (a *actions) RootRemote(dir string) bool {
	_, ok := remoteRootFor(dir)
	return ok
}
