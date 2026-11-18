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

	"agentpicker/state"
)

// wtTimeout bounds one wt call; the picker shows "running wt ..." meanwhile.
var wtTimeout = 60 * time.Second

// wtBinary is the wt script (git/.local/bin/wt, stowed to ~/.local/bin):
// AGENT_SESSIONS_WT, else wt on PATH, else ~/.local/bin/wt, since the tmux
// server's PATH may lack ~/.local/bin.
func wtBinary() string {
	if p := os.Getenv("AGENT_SESSIONS_WT"); p != "" {
		return p
	}
	if p, err := exec.LookPath("wt"); err == nil {
		return p
	}
	return filepath.Join(os.Getenv("HOME"), ".local/bin/wt")
}

// resurrectSavePath is the verified save entrypoint (tmux/scripts/
// resurrect_save.sh, as Continuum and the timer run it).
// AGENT_SESSIONS_RESURRECT_SAVE overrides it; tests must point it at a shim.
func resurrectSavePath() string {
	if p := os.Getenv("AGENT_SESSIONS_RESURRECT_SAVE"); p != "" {
		return p
	}
	return filepath.Join(os.Getenv("HOME"), ".config/tmux/scripts/resurrect_save.sh")
}

// runWT runs `wt OP ARGS... --json` (no shell, stdin /dev/null) and decodes
// its one JSON object into out. A non-zero exit is a *state.WTError with
// wt's code and its JSON "error", else the first line of stderr.
func runWT(op string, out any, args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), wtTimeout)
	defer cancel()
	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, wtBinary(), append(append([]string{op}, args...), "--json")...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	cmd.WaitDelay = time.Second // a child holding the pipes cannot outlast the timeout
	err := cmd.Run()
	if ctx.Err() == context.DeadlineExceeded {
		return &state.WTError{Op: op, Code: -1, Msg: fmt.Sprintf("timed out after %s", wtTimeout)}
	}
	if err != nil {
		var exitErr *exec.ExitError
		if !errors.As(err, &exitErr) {
			return &state.WTError{Op: op, Code: -1, Msg: err.Error()}
		}
		var reply struct {
			Error string `json:"error"`
		}
		msg := ""
		if json.Unmarshal(lastLine(stdout.String()), &reply) == nil {
			msg = reply.Error
		}
		if msg == "" {
			msg = strings.TrimPrefix(firstLine(stderr.String()), "wt: ")
		}
		if msg == "" {
			msg = fmt.Sprintf("exit %d", exitErr.ExitCode())
		}
		return &state.WTError{Op: op, Code: exitErr.ExitCode(), Msg: msg}
	}
	if err := json.Unmarshal(lastLine(stdout.String()), out); err != nil {
		return &state.WTError{Op: op, Code: -1, Msg: "unreadable reply: " + firstLine(stdout.String())}
	}
	return nil
}

// lastLine is the last non-blank line of s: wt prints one JSON object.
func lastLine(s string) []byte {
	lines := strings.Split(strings.TrimSpace(s), "\n")
	return []byte(strings.TrimSpace(lines[len(lines)-1]))
}

func (a *actions) WorktreeNew(root, branch, from string) (state.WTResult, error) {
	args := []string{root, "--branch", branch}
	if from != "" {
		args = append(args, "--from", from)
	}
	var r state.WTResult
	// Even a failed new can leave a worktree behind ("created at ..., but").
	a.rediscover = true
	return r, runWT("new", &r, args...)
}

func (a *actions) WorktreeStatus(root string) (state.WTStatus, error) {
	var s state.WTStatus
	return s, runWT("status", &s, root)
}

func (a *actions) WorktreeRepurpose(root, branch string) (state.WTResult, error) {
	args := []string{root, "--branch", branch, "--stash"}
	var r state.WTResult
	a.rediscover = true // the branch is part of the discovered entry
	return r, runWT("repurpose", &r, args...)
}

func (a *actions) WorktreeRemove(root string) (state.WTResult, error) {
	var r state.WTResult
	a.rediscover = true
	return r, runWT("rm", &r, root)
}

func (a *actions) WorktreeEnvRefresh(root string, here bool) (state.WTEnvResult, error) {
	args := []string{root}
	if here {
		args = append(args, "--here")
	}
	var r state.WTEnvResult
	return r, runWT("env-refresh", &r, args...) // files only: no rescan needed
}

// SaveLayout starts resurrect_save.sh quiet in its own session with every
// stream on /dev/null, and does not wait: it outlives the popup.
func (a *actions) SaveLayout() error {
	p := resurrectSavePath()
	if !isExecutable(p) {
		return fmt.Errorf("resurrect save not started: %s is missing", p)
	}
	cmd := exec.Command(p, "quiet")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("resurrect save not started: %v", err)
	}
	return cmd.Process.Release()
}
