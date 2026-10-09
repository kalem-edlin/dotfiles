package tmuxio

import (
	"os"
	"reflect"
	"strings"
	"testing"

	"agentpicker/state"
)

// loadRows reads testdata/list-panes: fields separated by "|" (U+241E in
// real output), with "\t", "\r" and "\n" standing for the raw characters.
func loadRows(t *testing.T) string {
	t.Helper()
	b, err := os.ReadFile("testdata/list-panes")
	if err != nil {
		t.Fatal(err)
	}
	return strings.NewReplacer("|", sep, `\t`, "\t", `\r`, "\r", `\n`, "\n").Replace(string(b))
}

func loadMem(t *testing.T) map[int]int64 {
	t.Helper()
	b, err := os.ReadFile("testdata/mem")
	if err != nil {
		t.Fatal(err)
	}
	return parseMem(string(b))
}

func sessionIDs(s *state.Snapshot) []string {
	var ids []string
	for _, x := range s.Sessions {
		ids = append(ids, x.ID)
	}
	return ids
}

func findPane(t *testing.T, s *state.Snapshot, id string) *state.Pane {
	t.Helper()
	for _, x := range s.Sessions {
		for _, w := range x.Windows {
			for _, p := range w.Panes {
				if p.ID == id {
					return p
				}
			}
		}
	}
	t.Fatalf("pane %s not found", id)
	return nil
}

func findSession(t *testing.T, s *state.Snapshot, id string) *state.Session {
	t.Helper()
	for _, x := range s.Sessions {
		if x.ID == id {
			return x
		}
	}
	t.Fatalf("session %s not found", id)
	return nil
}

func TestParseOrderCurrentLast(t *testing.T) {
	snap := parseSnapshot("$2\n"+loadRows(t), loadMem(t), 1800000000)
	if snap.CurrentID != "$2" || snap.Now != 1800000000 {
		t.Fatalf("CurrentID %q Now %d", snap.CurrentID, snap.Now)
	}
	// No agents first by last attach, then $7 (an idle agent with a state
	// time), $6 (1 working) and $1 (1 of each), the client's session last.
	want := []string{"$5", "$4", "$3", "$7", "$6", "$1", "$2"}
	if got := sessionIDs(snap); !reflect.DeepEqual(got, want) {
		t.Errorf("order %v, want %v", got, want)
	}
	for _, s := range snap.Sessions {
		if s.Current != (s.ID == "$2") {
			t.Errorf("%s Current=%v", s.ID, s.Current)
		}
	}
	if s := findSession(t, snap, "$1"); s.LastAttached != 3000 || s.Name != "api" {
		t.Errorf("$1 = %q %d", s.Name, s.LastAttached)
	}
}

func TestParseNoClient(t *testing.T) {
	snap := parseSnapshot("\n"+loadRows(t), loadMem(t), 0)
	want := []string{"$5", "$2", "$4", "$3", "$7", "$6", "$1"}
	if got := sessionIDs(snap); !reflect.DeepEqual(got, want) {
		t.Errorf("order %v, want %v", got, want)
	}
	if snap.CurrentID != "" {
		t.Errorf("CurrentID %q", snap.CurrentID)
	}
	for _, s := range snap.Sessions {
		if s.Current {
			t.Errorf("%s is Current without a client", s.ID)
		}
	}
}

func TestParseTreeAndBackPointers(t *testing.T) {
	snap := parseSnapshot("$2\n"+loadRows(t), loadMem(t), 0)
	api := findSession(t, snap, "$1")
	var got []string
	for _, w := range api.Windows {
		var panes []string
		for _, p := range w.Panes {
			panes = append(panes, p.ID)
			if p.Window != w {
				t.Errorf("%s.Window wrong", p.ID)
			}
		}
		got = append(got, w.ID+":"+strings.Join(panes, ","))
		if w.Session != api {
			t.Errorf("%s.Session wrong", w.ID)
		}
	}
	// Windows by index (10 after 3), panes by index (%1 before %2).
	want := []string{"@1:%1,%2", "@2:%3,%4", "@3:%5,%6,%7", "@10:%20"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("tree %v, want %v", got, want)
	}
	if w := api.Windows[0]; !w.Active || w.Name != "editor" || w.Index != 1 {
		t.Errorf("@1 = %+v", w)
	}
	if api.Windows[1].Active {
		t.Error("@2 should not be active")
	}
	if p := api.Windows[0].Panes[0]; !p.Active || p.Index != 0 || p.PID != 101 || p.Command != "nvim" {
		t.Errorf("%%1 = %+v", p)
	}
}

// @agent_empty=1 marks an empty chat (D59); anything else does not.
func TestParseAgentEmpty(t *testing.T) {
	snap := parseSnapshot("$2\n"+loadRows(t), loadMem(t), 0)
	if !findPane(t, snap, "%2").AgentEmpty {
		t.Error("%2 should be an empty chat")
	}
	if findPane(t, snap, "%3").AgentEmpty {
		t.Error("%3 should not be")
	}
}

func TestParsePanes(t *testing.T) {
	snap := parseSnapshot("$2\n"+loadRows(t), loadMem(t), 0)

	type view struct {
		Kind, Name  string
		State       state.State
		At, StateAt int64
		Subs        string
		Remote      bool
		HasMem      bool
		MemKB       int64
		LastCommand string
	}
	pv := func(p *state.Pane) view {
		return view{p.AgentKind, p.AgentName, p.State, p.AgentAt, p.StateAt, p.Subs,
			p.Remote, p.HasMem, p.MemKB, p.LastCommand}
	}
	cases := map[string]view{
		// Plain shell pane, memory only.
		"%1": {HasMem: true, MemKB: 300000, LastCommand: "nvim ."},
		// Live agent with @agent_state_at and @workspace-last-command.
		"%2": {"claude", "fix tests", state.StateWorking, 1799999000, 1799998000, "2", false, true, 200000, "claude --resume"},
		// @agent_pid 202 is not alive: no agent, memory kept.
		"%3": {HasMem: true, MemKB: 100000},
		// Unknown state reads as idle; empty state too.
		"%4": {"claude", "weird state", state.StateIdle, 1799999100, 0, "0", false, true, 50000, ""},
		"%5": {"claude", "plan", state.StateAwaiting, 1799999200, 1799999150, "1", false, true, 3000, "pnpm branch"},
		"%6": {"pi", "done", state.StateDone, 1799999300, 1799999250, "0", false, true, 2000, ""},
		"%7": {"claude", "no state", state.StateIdle, 1799999400, 0, "0", false, true, 1383, ""},
		// Remote: no memory, no agent, even with a live @agent_pid.
		"%10": {Remote: true, LastCommand: "rw attach"},
		"%11": {Remote: true, LastCommand: "rw attach"},
		// Pane pid missing from pane-mem: no memory.
		"%12": {},
		// A multi-line command line spreads the record over lines.
		"%8": {HasMem: true, MemKB: 2516582, LastCommand: "cat <<X line two X"},
		// Tabs and carriage returns become spaces.
		"%13": {"claude", "agent na me", state.StateWorking, 1799990000, 0, "0", false, true, 2048, ""},
		// No @agent_pid: the agent counts as live, as in v1.
		"%14": {"claude", "no pid agent", state.StateIdle, 1799990100, 0, "0", false, false, 0, ""},
	}
	for id, want := range cases {
		if got := pv(findPane(t, snap, id)); got != want {
			t.Errorf("%s\n got %+v\nwant %+v", id, got, want)
		}
	}
}

func TestParseOddNames(t *testing.T) {
	snap := parseSnapshot("$2\n"+loadRows(t), loadMem(t), 0)
	checks := []struct{ got, want string }{
		{findSession(t, snap, "$2").Name, "client sess"},
		{findSession(t, snap, "$6").Name, "tab name"},
		{findSession(t, snap, "$6").Windows[0].Name, "win dow"},
		{findPane(t, snap, "%13").Command, "cmd x"},
		{findSession(t, snap, "$7").Name, `we;ird "n'ame" ✔ 日本 $HOME`},
		{findSession(t, snap, "$7").Windows[0].Name, "a b; c"},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("got %q, want %q", c.got, c.want)
		}
	}
}

// Paths are kept raw: spaces, odd characters and even a line break survive,
// and an unset @pane_focus_at reads as 0. Every pane gets them, agent or not.
func TestParsePathsAndFocus(t *testing.T) {
	snap := parseSnapshot("$2\n"+loadRows(t), loadMem(t), 0)
	type view struct {
		Path, AgentCwd, Dir string
		FocusAt             int64
	}
	cases := map[string]view{
		// Live agent with a published cwd: Dir is the agent's cwd.
		"%2": {"/src/api", "/src/api wt/feature x", "/src/api wt/feature x", 1799999900},
		// Plain pane, no focus stamp.
		"%1": {"/src/my proj/a;b 日本", "", "/src/my proj/a;b 日本", 0},
		// Dead agent: its stale cwd is read but Dir falls back to the path.
		"%3": {"/src/api", "/stale/dead agent", "/src/api", 1799999800},
		// Live agent without a published cwd.
		"%4": {"/src/api", "", "/src/api", 0},
		// Remote pane: never an agent, so the path.
		"%10": {"/home/u", "/remote/cwd", "/home/u", 1799999960},
		// Multi-line command line ahead of the paths.
		"%8": {"/home/u", "", "/home/u", 1799999950},
		// A line break inside a path joins the record back up, raw.
		"%13": {"/tmp/line\nbreak", "/tmp/agent\tcwd", "/tmp/agent\tcwd", 1799990001},
		"%12": {},
	}
	for id, want := range cases {
		p := findPane(t, snap, id)
		if got := (view{p.Path, p.AgentCwd, p.Dir(), p.FocusAt}); got != want {
			t.Errorf("%s\n got %+v\nwant %+v", id, got, want)
		}
	}
}

func TestParseClientLine(t *testing.T) {
	cases := []struct{ first, sid, pid string }{
		{"$2" + sep + "%8", "$2", "%8"},
		{"$2", "$2", ""}, // an older line without the pane id
		{"", "", ""},
		{" $3 " + sep + " %9 ", "$3", "%9"},
	}
	for _, c := range cases {
		snap := parseSnapshot(c.first+"\n"+loadRows(t), loadMem(t), 0)
		if snap.CurrentID != c.sid || snap.CurrentPane != c.pid {
			t.Errorf("%q: %q %q, want %q %q", c.first, snap.CurrentID, snap.CurrentPane, c.sid, c.pid)
		}
	}
}

func TestParseEmptyAndShortRows(t *testing.T) {
	if snap := parseSnapshot("$1\n", nil, 0); len(snap.Sessions) != 0 || snap.CurrentID != "$1" {
		t.Errorf("empty: %+v", snap)
	}
	if snap := parseSnapshot("", nil, 0); len(snap.Sessions) != 0 {
		t.Errorf("no output: %+v", snap)
	}
	// A truncated last record is padded rather than dropped.
	row := strings.Join([]string{"$1", "s", "5", "@1", "0", "w", "1", "%1", "0", "1", "10", "zsh"}, sep)
	snap := parseSnapshot("\n"+row+"\n", map[int]int64{10: 7}, 0)
	if p := findPane(t, snap, "%1"); !p.HasMem || p.MemKB != 7 || p.State != state.StateNone {
		t.Errorf("short row pane %+v", p)
	}
}

func TestMemPIDs(t *testing.T) {
	_, rows := parseRows("$2\n" + loadRows(t))
	got := memPIDs(rows)
	want := []string{"102", "201", "101", "103", "202", "104", "203", "105", "204", "106", "205",
		"107", "206", "120", "111", "121", "122", "222", "131", "141", "151", "251", "161"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("pids\n got %v\nwant %v", got, want)
	}
}

func TestParseMem(t *testing.T) {
	got := parseMem("101 300\n\ngarbage\n102 x\n103 5 6\n104 0\n")
	want := map[int]int64{101: 300, 104: 0}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %v, want %v", got, want)
	}
}

func TestLoadWithClient(t *testing.T) {
	reset(t)
	fixture(t, "out-display-message", "$2"+sep+"%8\n"+loadRows(t))
	mem, _ := os.ReadFile("testdata/mem")
	fixture(t, "mem", string(mem))

	snap, err := New("/dev/ttys042").Load()
	if err != nil {
		t.Fatal(err)
	}
	expectCalls(t, tmuxLog, argv("display-message", "-p", "-c", "/dev/ttys042", "#{session_id}"+sep+"#{pane_id}", ";",
		"list-panes", "-a", "-F", listFormat))
	_, rows := parseRows("\n" + loadRows(t))
	expectCalls(t, memLog, memPIDs(rows))
	if got := sessionIDs(snap); !reflect.DeepEqual(got, []string{"$5", "$4", "$3", "$7", "$6", "$1", "$2"}) {
		t.Errorf("order %v", got)
	}
	if p := findPane(t, snap, "%3"); p.AgentKind != "" {
		t.Error("dead agent survived Load")
	}
	if snap.Now == 0 {
		t.Error("Now not set")
	}
	if snap.CurrentID != "$2" || snap.CurrentPane != "%8" {
		t.Errorf("client = %q %q", snap.CurrentID, snap.CurrentPane)
	}
}

func TestLoadNoClient(t *testing.T) {
	reset(t)
	fixture(t, "out-list-panes", loadRows(t))
	snap, err := New("").Load()
	if err != nil {
		t.Fatal(err)
	}
	expectCalls(t, tmuxLog, argv("list-panes", "-a", "-F", listFormat))
	if snap.CurrentID != "" || snap.CurrentPane != "" || len(snap.Sessions) != 7 {
		t.Errorf("CurrentID %q CurrentPane %q, %d sessions", snap.CurrentID, snap.CurrentPane, len(snap.Sessions))
	}
	// pane-mem printed nothing: every agent with a pid is dead.
	if p := findPane(t, snap, "%2"); p.AgentKind != "" || p.HasMem {
		t.Errorf("%%2 = %+v", p)
	}
}

func TestLoadTmuxError(t *testing.T) {
	reset(t)
	fixture(t, "fail-display-message", "can't find client: /dev/ttys042\n")
	_, err := New("/dev/ttys042").Load()
	if err == nil || err.Error() != "tmux display-message: can't find client: /dev/ttys042" {
		t.Errorf("err = %v", err)
	}
	expectCalls(t, memLog)
}

func TestListFormat(t *testing.T) {
	if len(fields) != nFields {
		t.Fatalf("%d fields, %d columns", len(fields), nFields)
	}
	if !strings.HasPrefix(listFormat, "#{session_id}"+sep+"#{session_name}") ||
		!strings.HasSuffix(listFormat, sep+"#{@agent_empty}"+sep+"#{pane_current_path}"+sep+"#{@agent_cwd}"+sep+"#{@pane_focus_at}"+sep+"#{session_attached}") {
		t.Errorf("format %q", listFormat)
	}
}

// orderSession is a session with one window of agent panes in the given
// states; at is the state change time of each, last its LastAttached.
func orderSession(id string, last int64, current bool, at int64, states ...state.State) *state.Session {
	s := &state.Session{ID: id, Name: id, LastAttached: last, Current: current}
	w := &state.Window{ID: "@" + id, Session: s}
	for _, st := range states {
		w.Panes = append(w.Panes, &state.Pane{State: st, StateAt: at, Window: w})
	}
	s.Windows = []*state.Window{w}
	return s
}

func sortedIDs(ss ...*state.Session) []string {
	sortRows(ss)
	return sessionIDs(&state.Snapshot{Sessions: ss})
}

func TestOrderPriority(t *testing.T) {
	aw, dn, wk := state.StateAwaiting, state.StateDone, state.StateWorking
	cases := []struct {
		name string
		ss   []*state.Session
		want []string
	}{
		{"current last", []*state.Session{
			orderSession("cur", 9, true, 0), orderSession("a", 1, false, 0, aw, aw), orderSession("b", 2, false, 0)},
			[]string{"b", "a", "cur"}},
		{"awaiting beats done", []*state.Session{
			orderSession("done3", 9, false, 9, dn, dn, dn), orderSession("aw1", 1, false, 1, aw)},
			[]string{"done3", "aw1"}},
		{"more awaiting wins", []*state.Session{
			orderSession("aw2", 1, false, 1, aw, aw), orderSession("aw1", 9, false, 9, aw)},
			[]string{"aw1", "aw2"}},
		{"done beats working", []*state.Session{
			orderSession("dn1", 1, false, 1, dn), orderSession("wk3", 9, false, 9, wk, wk, wk)},
			[]string{"wk3", "dn1"}},
		{"newest state change breaks a count tie", []*state.Session{
			orderSession("new", 1, false, 500, wk), orderSession("old", 9, false, 100, wk)},
			[]string{"old", "new"}},
		{"last attach breaks the rest", []*state.Session{
			orderSession("recent", 50, false, 100, wk), orderSession("stale", 10, false, 100, wk)},
			[]string{"stale", "recent"}},
		{"full ties keep tmux order", []*state.Session{
			orderSession("x", 5, false, 0), orderSession("y", 5, false, 0)},
			[]string{"x", "y"}},
	}
	for _, c := range cases {
		if got := sortedIDs(c.ss...); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}
