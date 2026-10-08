package tmuxio

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The harness never lets a test reach a real tmux server: tmuxPath is an
// absolute path to a shim that only logs its argv, PATH holds the shim dir
// plus /bin:/usr/bin, and TMUX/TMUX_PANE are unset. Any failed check aborts
// before a single test runs.

var (
	fakeDir  string // per-test fixtures: out-SUB, fail-SUB, rw-exit, mem
	tmuxLog  string // one line per tmux call, args terminated by \x1f
	rwLog    string
	memLog   string
	shimTmux string
	shimRW   string
	homeDir  string
)

func TestMain(m *testing.M) {
	os.Exit(runTests(m))
}

func runTests(m *testing.M) int {
	tmp, err := os.MkdirTemp("", "tmuxio-test.")
	if err != nil {
		fmt.Fprintln(os.Stderr, "ABORT:", err)
		return 1
	}
	defer os.RemoveAll(tmp)
	if err := setupHarness(tmp); err != nil {
		fmt.Fprintln(os.Stderr, "ABORT:", err)
		return 1
	}
	return m.Run()
}

func setupHarness(tmp string) error {
	bin := filepath.Join(tmp, "bin")
	fakeDir = filepath.Join(tmp, "fake")
	homeDir = filepath.Join(tmp, "home")
	for _, d := range []string{bin, fakeDir, homeDir, filepath.Join(tmp, "tmux-tmpdir")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return err
		}
	}
	tmuxLog = filepath.Join(tmp, "tmux.log")
	rwLog = filepath.Join(tmp, "rw.log")
	memLog = filepath.Join(tmp, "mem.log")

	logArgs := func(log string) string {
		return fmt.Sprintf("for a in \"$@\"; do printf '%%s\\037' \"$a\"; done >>'%s'\nprintf '\\n' >>'%s'\n", log, log)
	}
	shimTmux = filepath.Join(bin, "tmux")
	shimRW = filepath.Join(bin, "rw-close.sh")
	shimMem := filepath.Join(bin, "pane-mem")
	shims := map[string]string{
		shimTmux: logArgs(tmuxLog) + fmt.Sprintf(
			"if [ -f '%[1]s/fail-'\"$1\" ]; then /bin/cat '%[1]s/fail-'\"$1\" >&2; exit 1; fi\n"+
				"if [ -f '%[1]s/out-'\"$1\" ]; then /bin/cat '%[1]s/out-'\"$1\"; fi\n"+
				"exit 0\n", fakeDir),
		shimRW: logArgs(rwLog) + fmt.Sprintf(
			"if [ -f '%[1]s/rw-exit' ]; then echo 'ssh: connect to host: refused' >&2; exit \"$(/bin/cat '%[1]s/rw-exit')\"; fi\n"+
				"exit 0\n", fakeDir),
		shimMem: logArgs(memLog) + fmt.Sprintf(
			"if [ -f '%[1]s/mem' ]; then /bin/cat '%[1]s/mem'; fi\nexit 0\n", fakeDir),
	}
	for path, body := range shims {
		if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
			return err
		}
	}

	tmuxPath = shimTmux
	rwClosePath = shimRW
	paneMemPath = shimMem
	if !filepath.IsAbs(tmuxPath) || tmuxPath != shimTmux {
		return fmt.Errorf("tmuxPath %q is not the shim", tmuxPath)
	}

	if err := os.Setenv("PATH", bin+":/bin:/usr/bin"); err != nil {
		return err
	}
	for _, k := range []string{"TMUX", "TMUX_PANE"} {
		if err := os.Unsetenv(k); err != nil {
			return err
		}
		if _, set := os.LookupEnv(k); set {
			return fmt.Errorf("%s is still set", k)
		}
	}
	if p, err := exec.LookPath("tmux"); err == nil && p != shimTmux {
		return fmt.Errorf("tmux resolves to %q, not the shim", p)
	}
	os.Setenv("TMUX_TMPDIR", filepath.Join(tmp, "tmux-tmpdir"))
	os.Setenv("HOME", homeDir)
	os.Unsetenv("AGENT_SESSIONS_RW_CLOSE")

	// The shim must answer and log before anything else calls it.
	if _, err := runTmux("guard-check"); err != nil {
		return fmt.Errorf("shim check: %v", err)
	}
	if got, _ := os.ReadFile(tmuxLog); string(got) != "guard-check\x1f\n" {
		return fmt.Errorf("shim check: log %q", got)
	}
	return nil
}

// reset clears fixtures and logs between cases.
func reset(t *testing.T) {
	t.Helper()
	entries, _ := os.ReadDir(fakeDir)
	for _, e := range entries {
		os.Remove(filepath.Join(fakeDir, e.Name()))
	}
	for _, f := range []string{tmuxLog, rwLog, memLog} {
		if err := os.WriteFile(f, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// fixture writes fakeDir/name.
func fixture(t *testing.T, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(fakeDir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// calls reads a shim log as one argv per call.
func calls(t *testing.T, log string) [][]string {
	t.Helper()
	b, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	var out [][]string
	for _, line := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if line == "" {
			continue
		}
		args := strings.Split(line, "\x1f")
		out = append(out, args[:len(args)-1])
	}
	return out
}

func expectCalls(t *testing.T, log string, want ...[]string) {
	t.Helper()
	got := calls(t, log)
	if len(got) == 0 && len(want) == 0 {
		return
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("%s calls\n got: %q\nwant: %q", filepath.Base(log), got, want)
	}
}

func argv(a ...string) []string { return a }
