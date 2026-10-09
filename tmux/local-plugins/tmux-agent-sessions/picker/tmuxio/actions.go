package tmuxio

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"agentpicker/state"
)

// tmuxPath is the tmux binary. Tests point it at a shim.
var tmuxPath = "tmux"

// rwClosePath is tmux-remote-workspaces' rw-close.sh, the same route as the
// live `prefix q` binding, so remote endpoints are tombstoned instead of
// orphaned. AGENT_SESSIONS_RW_CLOSE overrides it, as in v1.
var rwClosePath = defaultRWClose()

const rwReason = "agent-sessions-picker"

func defaultRWClose() string {
	if p := os.Getenv("AGENT_SESSIONS_RW_CLOSE"); p != "" {
		return p
	}
	return filepath.Join(os.Getenv("HOME"), ".config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw-close.sh")
}

type actions struct {
	client string // #{client_name} of the invoking client, may be empty
}

// New returns the tmux-backed Actions for the client named client. Targets
// are always ids ($N, @N, %N); names are passed only where tmux needs one.
func New(client string) state.Actions {
	return &actions{client: client}
}

// clientArgs is "-c CLIENT", or nothing when the client is unknown so tmux
// picks the current one (v1 passed an empty -c).
func (a *actions) clientArgs() []string {
	if a.client == "" {
		return nil
	}
	return []string{"-c", a.client}
}

func (a *actions) Switch(s *state.Session, w *state.Window, p *state.Pane) error {
	if w == nil && p != nil {
		w = p.Window
	}
	args := append([]string{"switch-client"}, a.clientArgs()...)
	switch {
	case w != nil:
		args = append(args, "-t", w.ID, ";", "select-window", "-t", w.ID)
		if p != nil {
			args = append(args, ";", "select-pane", "-t", p.ID)
		}
	case s != nil:
		args = append(args, "-t", s.ID)
	default:
		return errors.New("no session selected")
	}
	_, err := runTmux(args...)
	return err
}

func (a *actions) CreateSession(name string) error {
	if err := checkSessionName(name); err != nil {
		return err
	}
	// `=NAME:` is an exact session match; a bare name would also match
	// window names in the current session.
	args := []string{"new-session", "-d", "-s", name, "-c", home(), ";", "switch-client"}
	args = append(args, a.clientArgs()...)
	args = append(args, "-t", "="+name+":")
	_, err := runTmux(args...)
	return err
}

// NewSession creates a detached session in dir (home when empty). An empty
// name is a cancel, as at v1's prompt; the UI offers a default.
func (a *actions) NewSession(name, dir string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	if err := checkSessionName(name); err != nil {
		return err
	}
	if dir == "" {
		dir = home()
	}
	_, err := runTmux("new-session", "-d", "-s", name, "-c", dir)
	return err
}

func (a *actions) NewWindow(s *state.Session, dir, name string) error {
	if s == nil {
		return errors.New("no session selected")
	}
	name = strings.TrimSpace(name)
	cwd := dir
	if cwd == "" {
		// Mirror the live `prefix c` (new-window -c "#{pane_current_path}")
		// using the selected session's active pane.
		out, err := runTmux("display-message", "-p", "-t", s.ID, "#{pane_current_path}")
		if err != nil {
			return err
		}
		cwd = strings.TrimRight(out, "\n")
	}
	if cwd == "" {
		cwd = home()
	}
	args := []string{"new-window", "-d", "-t", s.ID + ":", "-c", cwd}
	if name != "" {
		args = append(args, "-n", name)
	}
	_, err := runTmux(args...)
	return err
}

// RenameWindow renames w. An empty name is a cancel, as in v1.
func (a *actions) RenameWindow(w *state.Window, name string) error {
	if w == nil {
		return errors.New("no window selected")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	_, err := runTmux("rename-window", "-t", w.ID, name)
	return err
}

// RenameSession renames s. An empty name is a cancel, as in v1.
func (a *actions) RenameSession(s *state.Session, name string) error {
	if s == nil {
		return errors.New("no session selected")
	}
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	if err := checkSessionName(name); err != nil {
		return err
	}
	_, err := runTmux("rename-session", "-t", s.ID, name)
	return err
}

// KillPane kills p. A remote pane goes only through rw-close.sh, which
// closes the pane itself. @remote-host is read fresh, not from the snapshot.
func (a *actions) KillPane(p *state.Pane) error {
	if p == nil {
		return errors.New("no pane selected")
	}
	host, err := runTmux("display-message", "-p", "-t", p.ID, "#{@remote-host}")
	if err != nil {
		return err
	}
	host = strings.TrimRight(host, "\n")
	if host == "" {
		_, err := runTmux("kill-pane", "-t", p.ID)
		return err
	}
	if !isExecutable(rwClosePath) {
		return fmt.Errorf("remote pane %s (%s) but rw-close.sh is missing: %s", p.ID, host, rwClosePath)
	}
	if out, err := runRWClose("--pane", p.ID, "--reason", rwReason); err != nil {
		return fmt.Errorf("rw-close.sh failed for %s (%s)%s", p.ID, host, detail(out))
	}
	return nil
}

func (a *actions) KillWindow(w *state.Window) error {
	if w == nil {
		return errors.New("no window selected")
	}
	failed, err := closeRemotePanes("list-panes", "-t", w.ID)
	if err != nil {
		return err
	}
	if _, err := runTmux("kill-window", "-t", w.ID); err != nil {
		return err
	}
	return killedAnyway(failed)
}

func (a *actions) KillSession(s *state.Session) error {
	if s == nil {
		return errors.New("no session selected")
	}
	failed, err := closeRemotePanes("list-panes", "-s", "-t", s.ID)
	if err != nil {
		return err
	}
	if _, err := runTmux("kill-session", "-t", s.ID); err != nil {
		return err
	}
	return killedAnyway(failed)
}

// closeRemotePanes routes every remote pane listed by the given list-panes
// call through rw-close.sh. Panes are left for the caller's kill-window or
// kill-session (--no-kill-pane), as in rw-close-window.sh. err means the
// kill must not go ahead; failed lists panes rw-close.sh could not close,
// which v1 reported and then killed anyway.
func closeRemotePanes(listArgs ...string) (failed []string, err error) {
	out, err := runTmux(append(listArgs, "-F", "#{pane_id}\t#{@remote-host}")...)
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(out, "\n") {
		pane, host, _ := strings.Cut(line, "\t")
		if pane == "" || host == "" {
			continue
		}
		if !isExecutable(rwClosePath) {
			return nil, fmt.Errorf("remote pane %s (%s) but rw-close.sh is missing: %s; not killing", pane, host, rwClosePath)
		}
		if out, err := runRWClose("--pane", pane, "--no-kill-pane", "--reason", rwReason); err != nil {
			failed = append(failed, fmt.Sprintf("%s (%s)%s", pane, host, detail(out)))
		}
	}
	return failed, nil
}

func killedAnyway(failed []string) error {
	if len(failed) == 0 {
		return nil
	}
	return fmt.Errorf("rw-close.sh failed for %s; killed anyway", strings.Join(failed, ", "))
}

// checkSessionName: tmux replaces '.' and ':' in session names, and an empty
// name means automatic numbering, so reject all three up front.
func checkSessionName(name string) error {
	if name == "" {
		return errors.New("session name is empty")
	}
	if strings.ContainsAny(name, ".:") {
		return fmt.Errorf("session name cannot contain '.' or ':' (tmux would rewrite it): %s", name)
	}
	return nil
}

// runTmux runs one tmux call with argv (no shell) and returns its stdout.
// A failure reads "tmux SUBCOMMAND: first line of stderr".
func runTmux(args ...string) (string, error) {
	var stdout, stderr bytes.Buffer
	cmd := exec.Command(tmuxPath, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := firstLine(stderr.String())
		if msg == "" {
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				msg = "failed"
			} else {
				msg = err.Error()
			}
		}
		sub := ""
		if len(args) > 0 {
			sub = args[0]
		}
		return "", fmt.Errorf("tmux %s: %s", sub, msg)
	}
	return stdout.String(), nil
}

// runRWClose runs rw-close.sh with its output captured, so nothing writes
// over the picker. stdin is /dev/null: rw-close.sh reaches ssh.
func runRWClose(args ...string) (string, error) {
	out, err := exec.Command(rwClosePath, args...).CombinedOutput()
	return string(out), err
}

// detail is ": first line of out", or nothing when out is empty.
func detail(out string) string {
	if l := firstLine(out); l != "" {
		return ": " + l
	}
	return ""
}

// firstLine is the first non-blank line, for one-line error reports.
func firstLine(s string) string {
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return l
		}
	}
	return ""
}

func isExecutable(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
}

func home() string {
	if h, err := os.UserHomeDir(); err == nil {
		return h
	}
	return "/"
}
