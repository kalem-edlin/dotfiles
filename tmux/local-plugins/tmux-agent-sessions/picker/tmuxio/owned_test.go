package tmuxio

import (
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"agentpicker/state"
	"agentpicker/worktree"
)

// writeRecord writes owned/<id>/record.json under the scratch rw state dir.
func writeRecord(t *testing.T, id, body string) {
	t.Helper()
	dir := filepath.Join(rwState, "owned", id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "record.json"), []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}

const (
	parkedRecord = `{"root_id":"999","root_rel":"dev/parked","root_local":"/dev/parked","kind":"git","worker":"w1","worker_root":"/w/dev/parked","owner":"worker","since":"2026-11-18T00:00:00Z","endpoints":["e1"]}`
	focusRecord  = `{"root_id":"777","root_rel":"dev/back","root_local":"/dev/back","kind":"plain","worker":"w1","owner":"focus","endpoints":[],"pending":{"action":"reconcile","reason":"x","at":"y"}}`
)

// Records are plain files: worker-owned ones count, focus-owned (pending)
// ones and unreadable ones do not. The nearest enclosing root wins.
func TestReadOwnership(t *testing.T) {
	reset(t)
	if o := readOwnership(); len(o.byRoot) != 0 {
		t.Fatalf("no state dir: %v", o.byRoot)
	}
	writeRecord(t, "999", parkedRecord)
	writeRecord(t, "777", focusRecord)
	writeRecord(t, "555", `{"root_id":"555","root_local":"/dev/parked/inner","worker":"w2","owner":"worker"}`)
	writeRecord(t, "bad", "{not json")
	o := readOwnership()
	if len(o.byRoot) != 2 || !o.byID["999"] || o.byID["777"] {
		t.Errorf("ownership %v %v", o.byRoot, o.byID)
	}
	for dir, want := range map[string]string{
		"/dev/parked":           "w1",
		"/dev/parked/src/a":     "w1",
		"/dev/parked/inner/x":   "w2",
		"/dev/parkedness":       "",
		"/dev/back":             "",
		"/":                     "",
		"":                      "",
		"/dev/parked/inner/../": "w1",
	} {
		r, ok := o.rootFor(dir)
		if ok != (want != "") || r.Worker != want {
			t.Errorf("rootFor(%q) = %q %v, want %q", dir, r.Worker, ok, want)
		}
	}
}

// The snapshot marks a pane remote by @rw-root-id and a worktree remote by
// its root (D10); without records nothing changes.
func TestSnapshotOwnership(t *testing.T) {
	reset(t)
	entries := []worktree.Entry{{Info: worktree.Info{Root: "/dev/parked", Repo: "r", Branch: "b"}, Name: "parked"}, {Info: worktree.Info{Root: "/dev/other", Repo: "r", Branch: "c"}, Name: "other"}}
	cl, rows := parseRows("\n" + loadRows(t))

	snap := buildSnapshot(cl, rows, loadMem(t), 0, entries, ownership{})
	if p := findPane(t, snap, "%4"); p.Remote || p.RootID != "999" {
		t.Errorf("no records: %%4 remote=%v root=%q", p.Remote, p.RootID)
	}
	if p := findPane(t, snap, "%11"); !p.Remote || p.RootID != "4242" {
		t.Errorf("@remote-host: %%11 remote=%v root=%q", p.Remote, p.RootID)
	}

	writeRecord(t, "999", parkedRecord)
	snap = buildSnapshot(cl, rows, loadMem(t), 0, entries, readOwnership())
	// Remote by its root id: no memory, but its agent stays (R1: rw mirrors
	// a remote agent's options onto the pane).
	if p := findPane(t, snap, "%4"); !p.Remote || p.HasMem || p.AgentKind != "claude" {
		t.Errorf("owned root id: %%4 = %+v", p)
	}
	got := map[string]bool{}
	for _, w := range snap.Worktrees {
		got[w.Root] = w.Remote
	}
	if want := map[string]bool{"/dev/parked": true, "/dev/other": false}; !reflect.DeepEqual(got, want) {
		t.Errorf("worktree remote %v", got)
	}
}

func TestLoadReadsRecords(t *testing.T) {
	reset(t)
	writeRecord(t, "999", parkedRecord)
	fixture(t, "out-list-panes", loadRows(t))
	a := New("").(*actions)
	a.discovered = []worktree.Entry{{Info: worktree.Info{Root: "/dev/parked", Repo: "r", Branch: "b"}, Name: "parked"}}
	snap, err := a.Load()
	if err != nil {
		t.Fatal(err)
	}
	if !findPane(t, snap, "%4").Remote || !snap.Worktrees[0].Remote {
		t.Error("Load ignored the ownership records")
	}
}

// rwCmdCalls is the rw shim's argv per call; rwEnv its TMUX_PANE lines.
func rwEnv(t *testing.T) string {
	b, _ := os.ReadFile(rwCmdLog + ".env")
	return string(b)
}

// w in a remote root: the new window's pane goes to `rw open` with the
// record's worker and root, TMUX_PANE unset so rw respawns that pane.
func TestNewWindowRemote(t *testing.T) {
	reset(t)
	t.Setenv("TMUX_PANE", "%1")
	writeRecord(t, "999", parkedRecord)
	fixture(t, "out-new-window", "%42\n")
	expectOK(t, New(client).NewWindow(&state.Session{ID: "$2"}, "/dev/parked/sub", "x"))
	expectCalls(t, tmuxLog, argv("new-window", "-d", "-t", "$2:", "-c", "/dev/parked/sub", "-n", "x", "-P", "-F", "#{pane_id}"))
	expectCalls(t, rwCmdLog, argv("open", "--worker", "w1", "--root", "/dev/parked", "--pane", "%42"))
	if env := rwEnv(t); env != "TMUX_PANE=unset\n" {
		t.Errorf("rw env %q", env)
	}
}

// An unreachable worker: the new pane is killed, nothing is left in the
// frozen copy, and the error says remote, never the worker's name.
func TestNewWindowRemoteUnreachable(t *testing.T) {
	reset(t)
	writeRecord(t, "999", parkedRecord)
	fixture(t, "out-new-window", "%42\n")
	fixture(t, "rw-exit-open", "6")
	fixture(t, "rw-out-open", "rw: worker 'w1' is unreachable\n")
	err := New(client).NewWindow(&state.Session{ID: "$2"}, "/dev/parked", "")
	expectErr(t, err, "parked is remote and the remote is unreachable; nothing opened")
	if strings.Contains(err.Error(), "w1") {
		t.Errorf("worker named: %v", err)
	}
	expectCalls(t, tmuxLog,
		argv("new-window", "-d", "-t", "$2:", "-c", "/dev/parked", "-P", "-F", "#{pane_id}"),
		argv("kill-pane", "-t", "%42"))

	reset(t)
	writeRecord(t, "999", parkedRecord)
	fixture(t, "out-new-window", "%42\n")
	fixture(t, "rw-exit-open", "7")
	fixture(t, "rw-out-open", "rw: rw open: that root is remote on 'w2', not 'w1'.\n")
	expectErr(t, New(client).NewWindow(&state.Session{ID: "$2"}, "/dev/parked", ""), "rw open refused parked: rw open: that root")
}

// rw missing: nothing is created at all.
func TestNewWindowRemoteNoRW(t *testing.T) {
	reset(t)
	t.Setenv("PATH", "/bin:/usr/bin")
	writeRecord(t, "999", parkedRecord)
	expectErr(t, New(client).NewWindow(&state.Session{ID: "$2"}, "/dev/parked", ""), "parked is remote, but rw is not installed")
	expectCalls(t, tmuxLog)
}

// enter on a bare remote worktree row: the session's first pane opens
// remote, then the client goes there.
func TestCreateSessionRemote(t *testing.T) {
	reset(t)
	writeRecord(t, "999", parkedRecord)
	fixture(t, "out-new-session", "%43\n")
	expectOK(t, New(client).CreateSession("parked", "/dev/parked"))
	expectCalls(t, tmuxLog,
		argv("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "parked", "-c", "/dev/parked"),
		argv("switch-client", "-c", client, "-t", "=parked:"))
	expectCalls(t, rwCmdLog, argv("open", "--worker", "w1", "--root", "/dev/parked", "--pane", "%43"))

	// A failed open kills the new session's only pane and does not switch.
	reset(t)
	writeRecord(t, "999", parkedRecord)
	fixture(t, "out-new-session", "%43\n")
	fixture(t, "rw-exit-open", "1")
	fixture(t, "rw-out-open", "rw: rw open: could not create the remote session for this pane.\n")
	expectErr(t, New(client).CreateSession("parked", "/dev/parked"), "rw open failed for parked: rw open: could not create")
	expectCalls(t, tmuxLog,
		argv("new-session", "-d", "-P", "-F", "#{pane_id}", "-s", "parked", "-c", "/dev/parked"),
		argv("kill-pane", "-t", "%43"))
}

// A focus-owned record (handed back) opens local as before.
func TestCreateSessionFocusOwned(t *testing.T) {
	reset(t)
	writeRecord(t, "777", focusRecord)
	expectOK(t, New(client).CreateSession("back", "/dev/back"))
	expectCalls(t, tmuxLog, argv("new-session", "-d", "-s", "back", "-c", "/dev/back", ";",
		"switch-client", "-c", client, "-t", "=back:"))
	expectCalls(t, rwCmdLog)
}

// A pending forget means the root was deleted here: not remote any more.
func TestPendingForgetNotRemote(t *testing.T) {
	reset(t)
	writeRecord(t, "999", `{"root_id":"999","root_rel":"dev/parked","root_local":"/dev/parked","worker":"w1","owner":"worker","endpoints":[],"pending":{"action":"forget","reason":"remote was unreachable","at":"x"}}`)
	writeRecord(t, "888", `{"root_id":"888","root_rel":"dev/rec","root_local":"/dev/rec","worker":"w1","owner":"worker","endpoints":[],"pending":{"action":"reconcile","reason":"x","at":"x"}}`)
	o := readOwnership()
	if o.byID["999"] || !o.byID["888"] {
		t.Errorf("ownership %v", o.byID)
	}
	a := New(client)
	if a.RootRemote("/dev/parked/x") || !a.RootRemote("/dev/rec/x") || a.RootRemote("/elsewhere") {
		t.Error("RootRemote disagrees with the records")
	}
}

// The error text is rw's last "rw: " line: earlier ones are progress.
func TestRWDetail(t *testing.T) {
	for out, want := range map[string]string{
		"rw: preflight ok\nrw: rw open: that root is remote on 'w2'.\n": ": rw open: that root is remote on 'w2'.",
		"progress\nrw: refused\ntrailing noise\n":                       ": refused",
		"plain failure\n\n": ": plain failure",
		"":                  "",
	} {
		if got := rwDetail(out); got != want {
			t.Errorf("rwDetail(%q) = %q, want %q", out, got, want)
		}
	}
}

// A timed-out rw dies with its whole process group (an ssh child would
// otherwise hold the pipes past the timeout).
func TestRunRWKillsGroup(t *testing.T) {
	reset(t)
	defer func(d time.Duration) { rwTimeout = d }(rwTimeout)
	rwTimeout = 300 * time.Millisecond
	pidFile := filepath.Join(t.TempDir(), "child")
	script := filepath.Join(t.TempDir(), "rw-hang")
	body := "#!/bin/sh\n/bin/sleep 30 &\necho $! >'" + pidFile + "'\nwait\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_, code, err := runRW(script, "open")
	if code != -1 || err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Errorf("code %d err %v", code, err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("took %s", d)
	}
	b, _ := os.ReadFile(pidFile)
	pid, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	if pid <= 0 {
		t.Fatalf("no child pid: %q", b)
	}
	time.Sleep(100 * time.Millisecond)
	if syscall.Kill(pid, 0) == nil {
		syscall.Kill(pid, syscall.SIGKILL)
		t.Errorf("child %d outlived the timeout", pid)
	}
}
