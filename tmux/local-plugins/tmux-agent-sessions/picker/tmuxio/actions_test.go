package tmuxio

import (
	"path/filepath"
	"strings"
	"testing"

	"agentpicker/state"
)

// Ported from tests/action-test.sh. Prompts, y/N and "press a key" moved to
// the UI, so those cases are gone; the argv assertions are kept.

const client = "/dev/ttys009"

const listFmt = "#{pane_id}\t#{@remote-host}"

var (
	s1 = &state.Session{ID: "$1", Name: "api"}
	w3 = &state.Window{ID: "@3", Session: s1}
	w5 = &state.Window{ID: "@5", Session: s1}
	p7 = &state.Pane{ID: "%7", Window: w3}
)

func expectErr(t *testing.T, err error, want string) {
	t.Helper()
	if err == nil {
		t.Fatalf("no error, want %q", want)
	}
	if !strings.Contains(err.Error(), want) {
		t.Errorf("error %q lacks %q", err, want)
	}
}

func expectOK(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
}

// ---------------------------------------------------------------- switch

func TestSwitchWindow(t *testing.T) {
	reset(t)
	expectOK(t, New(client).Switch(s1, w3, nil))
	expectCalls(t, tmuxLog, argv("switch-client", "-c", client, "-t", "@3", ";", "select-window", "-t", "@3"))
}

func TestSwitchPane(t *testing.T) {
	reset(t)
	expectOK(t, New(client).Switch(s1, w3, p7))
	expectCalls(t, tmuxLog, argv("switch-client", "-c", client, "-t", "@3", ";", "select-window", "-t", "@3",
		";", "select-pane", "-t", "%7"))
}

func TestSwitchPaneWithoutWindowUsesPaneWindow(t *testing.T) {
	reset(t)
	expectOK(t, New(client).Switch(s1, nil, p7))
	expectCalls(t, tmuxLog, argv("switch-client", "-c", client, "-t", "@3", ";", "select-window", "-t", "@3",
		";", "select-pane", "-t", "%7"))
}

func TestSwitchEmptySession(t *testing.T) {
	reset(t)
	expectOK(t, New(client).Switch(&state.Session{ID: "$4"}, nil, nil))
	expectCalls(t, tmuxLog, argv("switch-client", "-c", client, "-t", "$4"))
}

func TestSwitchNoClientOmitsFlag(t *testing.T) {
	reset(t)
	expectOK(t, New("").Switch(s1, w3, nil))
	expectCalls(t, tmuxLog, argv("switch-client", "-t", "@3", ";", "select-window", "-t", "@3"))
}

func TestSwitchTmuxError(t *testing.T) {
	reset(t)
	fixture(t, "fail-switch-client", "\ncan't find window: @3\nsecond line\n")
	err := New(client).Switch(s1, w3, nil)
	if err == nil || err.Error() != "tmux switch-client: can't find window: @3" {
		t.Errorf("err = %v", err)
	}
}

func TestSwitchNothing(t *testing.T) {
	reset(t)
	expectErr(t, New(client).Switch(nil, nil, nil), "no session selected")
	expectCalls(t, tmuxLog)
}

// -------------------------------------------------------- create-session

func TestCreateSession(t *testing.T) {
	reset(t)
	expectOK(t, New(client).CreateSession("work"))
	expectCalls(t, tmuxLog, argv("new-session", "-d", "-s", "work", "-c", homeDir, ";",
		"switch-client", "-c", client, "-t", "=work:"))
}

func TestCreateSessionOddName(t *testing.T) {
	reset(t)
	expectOK(t, New(client).CreateSession(`my "proj"; x`))
	expectCalls(t, tmuxLog, argv("new-session", "-d", "-s", `my "proj"; x`, "-c", homeDir, ";",
		"switch-client", "-c", client, "-t", `=my "proj"; x:`))
}

func TestCreateSessionRejects(t *testing.T) {
	for name, want := range map[string]string{
		"":    "session name is empty",
		"a.b": "cannot contain '.' or ':'",
		"a:b": "cannot contain '.' or ':'",
	} {
		reset(t)
		expectErr(t, New(client).CreateSession(name), want)
		expectCalls(t, tmuxLog)
	}
}

func TestCreateSessionDuplicate(t *testing.T) {
	reset(t)
	fixture(t, "fail-new-session", "duplicate session: work\n")
	expectErr(t, New(client).CreateSession("work"), "tmux new-session: duplicate session: work")
}

// ------------------------------------------------------------ new-window

func TestNewWindowNamed(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "/src/proj\n")
	expectOK(t, New(client).NewWindow(&state.Session{ID: "$2"}, "", " build "))
	expectCalls(t, tmuxLog,
		argv("display-message", "-p", "-t", "$2", "#{pane_current_path}"),
		argv("new-window", "-d", "-t", "$2:", "-c", "/src/proj", "-n", "build"))
}

func TestNewWindowAutomaticName(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "/src/proj\n")
	expectOK(t, New(client).NewWindow(&state.Session{ID: "$2"}, "", ""))
	expectCalls(t, tmuxLog,
		argv("display-message", "-p", "-t", "$2", "#{pane_current_path}"),
		argv("new-window", "-d", "-t", "$2:", "-c", "/src/proj"))
}

func TestNewWindowNoPathUsesHome(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "\n")
	expectOK(t, New(client).NewWindow(&state.Session{ID: "$2"}, "", ""))
	expectCalls(t, tmuxLog,
		argv("display-message", "-p", "-t", "$2", "#{pane_current_path}"),
		argv("new-window", "-d", "-t", "$2:", "-c", homeDir))
}

// A start directory (a worktree root) skips the active pane lookup.
func TestNewWindowInDir(t *testing.T) {
	reset(t)
	expectOK(t, New(client).NewWindow(&state.Session{ID: "$2"}, "/src/wt two", "x"))
	expectCalls(t, tmuxLog, argv("new-window", "-d", "-t", "$2:", "-c", "/src/wt two", "-n", "x"))
}

func TestNewWindowReadError(t *testing.T) {
	reset(t)
	fixture(t, "fail-display-message", "can't find session: $2\n")
	expectErr(t, New(client).NewWindow(&state.Session{ID: "$2"}, "", "x"), "tmux display-message: can't find session: $2")
	expectCalls(t, tmuxLog, argv("display-message", "-p", "-t", "$2", "#{pane_current_path}"))
}

// ----------------------------------------------------------- new-session

func TestNewSession(t *testing.T) {
	reset(t)
	expectOK(t, New(client).NewSession("proj", ""))
	expectCalls(t, tmuxLog, argv("new-session", "-d", "-s", "proj", "-c", homeDir))
}

func TestNewSessionInDir(t *testing.T) {
	reset(t)
	expectOK(t, New(client).NewSession("wt", "/src/wt"))
	expectCalls(t, tmuxLog, argv("new-session", "-d", "-s", "wt", "-c", "/src/wt"))
}

func TestNewSessionEmptyCancels(t *testing.T) {
	reset(t)
	expectOK(t, New(client).NewSession("  ", ""))
	expectCalls(t, tmuxLog)
}

func TestNewSessionRejectsDotted(t *testing.T) {
	reset(t)
	expectErr(t, New(client).NewSession("x.y", ""), "cannot contain")
	expectCalls(t, tmuxLog)
}

// --------------------------------------------------------- rename-window

func TestRenameWindow(t *testing.T) {
	reset(t)
	expectOK(t, New(client).RenameWindow(w3, "newname"))
	expectCalls(t, tmuxLog, argv("rename-window", "-t", "@3", "newname"))
}

func TestRenameWindowSpaces(t *testing.T) {
	reset(t)
	expectOK(t, New(client).RenameWindow(w5, " new name "))
	expectCalls(t, tmuxLog, argv("rename-window", "-t", "@5", "new name"))
}

func TestRenameWindowEmptyCancels(t *testing.T) {
	reset(t)
	expectOK(t, New(client).RenameWindow(w3, ""))
	expectCalls(t, tmuxLog)
}

func TestRenameWindowNoWindow(t *testing.T) {
	reset(t)
	expectErr(t, New(client).RenameWindow(nil, "x"), "no window selected")
	expectCalls(t, tmuxLog)
}

// -------------------------------------------------------- rename-session

func TestRenameSession(t *testing.T) {
	reset(t)
	expectOK(t, New(client).RenameSession(s1, "backend"))
	expectCalls(t, tmuxLog, argv("rename-session", "-t", "$1", "backend"))
}

func TestRenameSessionEmptyCancels(t *testing.T) {
	reset(t)
	expectOK(t, New(client).RenameSession(s1, ""))
	expectCalls(t, tmuxLog)
}

func TestRenameSessionRejectsColon(t *testing.T) {
	reset(t)
	expectErr(t, New(client).RenameSession(s1, "a:b"), "cannot contain")
	expectCalls(t, tmuxLog)
}

func TestRenameSessionError(t *testing.T) {
	reset(t)
	fixture(t, "fail-rename-session", "can't find session: $9\n")
	expectErr(t, New(client).RenameSession(&state.Session{ID: "$9"}, "x"), "tmux rename-session: can't find session: $9")
	expectCalls(t, tmuxLog, argv("rename-session", "-t", "$9", "x"))
}

// ------------------------------------------------------------------ kill

func TestKillLocalWindow(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%1\t\n%2\t\n")
	expectOK(t, New(client).KillWindow(w3))
	expectCalls(t, tmuxLog,
		argv("list-panes", "-t", "@3", "-F", listFmt),
		argv("kill-window", "-t", "@3"))
	expectCalls(t, rwLog)
}

func TestKillWindowRoutesRemotePanes(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%1\t\n%2\tworker-a\n%3\tworker-b\n")
	expectOK(t, New(client).KillWindow(w3))
	expectCalls(t, rwLog,
		argv("--pane", "%2", "--no-kill-pane", "--reason", "agent-sessions-picker"),
		argv("--pane", "%3", "--no-kill-pane", "--reason", "agent-sessions-picker"))
	expectCalls(t, tmuxLog,
		argv("list-panes", "-t", "@3", "-F", listFmt),
		argv("kill-window", "-t", "@3"))
}

func withRWClose(t *testing.T, path string) {
	t.Helper()
	old := rwClosePath
	rwClosePath = path
	t.Cleanup(func() { rwClosePath = old })
}

func TestKillWindowRWCloseMissingAborts(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%2\tworker-a\n")
	withRWClose(t, filepath.Join(fakeDir, "nope", "rw-close.sh"))
	expectErr(t, New(client).KillWindow(w3), "rw-close.sh is missing")
	expectCalls(t, tmuxLog, argv("list-panes", "-t", "@3", "-F", listFmt))
}

func TestKillWindowDefaultRWClosePathAborts(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%2\tworker-a\n")
	withRWClose(t, defaultRWClose()) // HOME is the empty test home
	expectErr(t, New(client).KillWindow(w3),
		homeDir+"/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw-close.sh")
	expectCalls(t, tmuxLog, argv("list-panes", "-t", "@3", "-F", listFmt))
}

func TestDefaultRWClose(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_RW_CLOSE", "")
	if got, want := defaultRWClose(), homeDir+"/.config/tmux/local-plugins/tmux-remote-workspaces/scripts/rw-close.sh"; got != want {
		t.Errorf("default %q, want %q", got, want)
	}
	t.Setenv("AGENT_SESSIONS_RW_CLOSE", "/x/rw-close.sh")
	if got := defaultRWClose(); got != "/x/rw-close.sh" {
		t.Errorf("override %q", got)
	}
}

func TestKillWindowRWCloseFailureStillKills(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%2\tworker-a\n")
	fixture(t, "rw-exit", "1")
	err := New(client).KillWindow(w3)
	expectErr(t, err, "rw-close.sh failed for %2 (worker-a): ssh: connect to host: refused; killed anyway")
	expectCalls(t, tmuxLog,
		argv("list-panes", "-t", "@3", "-F", listFmt),
		argv("kill-window", "-t", "@3"))
}

func TestKillLocalPane(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "\n")
	expectOK(t, New(client).KillPane(p7))
	expectCalls(t, tmuxLog,
		argv("display-message", "-p", "-t", "%7", "#{@remote-host}"),
		argv("kill-pane", "-t", "%7"))
	expectCalls(t, rwLog)
}

func TestKillRemotePaneOnlyThroughRWClose(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "worker-a\n")
	expectOK(t, New(client).KillPane(p7))
	expectCalls(t, tmuxLog, argv("display-message", "-p", "-t", "%7", "#{@remote-host}"))
	expectCalls(t, rwLog, argv("--pane", "%7", "--reason", "agent-sessions-picker"))
}

func TestKillRemotePaneRWCloseFailureDoesNotKill(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "worker-a\n")
	fixture(t, "rw-exit", "2")
	expectErr(t, New(client).KillPane(p7), "rw-close.sh failed for %7 (worker-a)")
	expectCalls(t, tmuxLog, argv("display-message", "-p", "-t", "%7", "#{@remote-host}"))
}

func TestKillRemotePaneRWCloseMissing(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "worker-a\n")
	withRWClose(t, filepath.Join(fakeDir, "nope"))
	expectErr(t, New(client).KillPane(p7), "rw-close.sh is missing")
	expectCalls(t, tmuxLog, argv("display-message", "-p", "-t", "%7", "#{@remote-host}"))
	expectCalls(t, rwLog)
}

func TestKillWindowTmuxError(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%1\t\n")
	fixture(t, "fail-kill-window", "can't find window: @3\n")
	expectErr(t, New(client).KillWindow(w3), "tmux kill-window: can't find window: @3")
}

func TestKillWindowListError(t *testing.T) {
	reset(t)
	fixture(t, "fail-list-panes", "can't find window: @3\n")
	expectErr(t, New(client).KillWindow(w3), "tmux list-panes: can't find window: @3")
	expectCalls(t, tmuxLog, argv("list-panes", "-t", "@3", "-F", listFmt))
}

func TestKillNothingSelected(t *testing.T) {
	reset(t)
	expectErr(t, New(client).KillWindow(nil), "no window selected")
	expectErr(t, New(client).KillPane(nil), "no pane selected")
	expectErr(t, New(client).KillSession(nil), "no session selected")
	expectCalls(t, tmuxLog)
}

// ---------------------------------------------------------- kill-session

func TestKillSession(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", "%1\t\n%4\tworker-a\n")
	expectOK(t, New(client).KillSession(s1))
	expectCalls(t, tmuxLog,
		argv("list-panes", "-s", "-t", "$1", "-F", listFmt),
		argv("kill-session", "-t", "$1"))
	expectCalls(t, rwLog, argv("--pane", "%4", "--no-kill-pane", "--reason", "agent-sessions-picker"))
}
