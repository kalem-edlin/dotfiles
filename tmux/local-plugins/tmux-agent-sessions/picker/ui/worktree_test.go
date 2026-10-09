package ui

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"agentpicker/state"
)

// wtree builds a worktree from member panes already linked into windows,
// in window and pane order, as tmuxio groups them.
func wtree(root, repo, branch, head string, panes ...*state.Pane) *state.Worktree {
	t := &state.Worktree{Root: root, Repo: repo, Branch: branch, Head: head}
	for _, p := range panes {
		p.Worktree = t
		t.Panes = append(t.Panes, p)
		if n := len(t.Windows); n == 0 || t.Windows[n-1] != p.Window {
			t.Windows = append(t.Windows, p.Window)
		}
	}
	return t
}

// wtFixture is three sessions whose panes sit in five worktrees of three
// repos, plus one pane in no repo. Worktrees in display order, the
// client's own (dotfiles) last:
//
//	yap-trial         main             yap shell
//	content-engine-5  detached         ce5 agent
//	content-engine-1  main             1 agent in the shared "agents" window
//	roll-hiring       exp/roll-hiring  2 agents and a shell in "agents", nvim in "edit"
//	dotfiles          main             picker window, the edit window's agent
func wtFixture() *state.Snapshot {
	cur := active(focused(5, agent("claude", "picker worktrees", state.StateWorking, 15, 800)))
	dotShell := shell("zsh", "go test ./...", 10)
	editAgent := agent("claude", "dotfiles docs", state.StateIdle, 3600, 300)
	editNvim := active(shell("nvim", "nvim roll.ts", 80))
	rhA := active(agent("claude", "hiring copy", state.StateAwaiting, 300, 500))
	rhB := focused(30, agent("pi", "hiring review", state.StateDone, 60, 300))
	ceA := agent("claude", "engine refactor", state.StateWorking, 120, 600)
	rhShell := shell("nvim", "nvim hiring.md", 100)
	ce5 := active(agent("claude", "ce5 audit", state.StateDone, 900, 400))
	yap := active(shell("zsh", "pnpm dev", 50))
	home := shell("zsh", "", 5)

	content := sess("$2", "content", now-60,
		win(1, "agents", true, rhA, rhB, ceA, rhShell),
		win(2, "ce5", false, ce5))
	content.Attached = true
	dot := sess("$1", "dotfiles", now,
		win(1, "picker", true, cur, dotShell),
		win(2, "edit", false, editAgent, editNvim))
	dot.Current, dot.Attached = true, true
	misc := sess("$3", "misc", now-600, win(1, "yap", true, yap, home))

	wts := []*state.Worktree{
		wtree("/dev/yap-trial", "yap-trial", "main", "", yap),
		wtree("/dev/content-engine-5", "content-engine-1", "", "1a2b3c4", ce5),
		wtree("/dev/content-engine-1", "content-engine-1", "main", "", ceA),
		wtree("/dev/roll-hiring", "content-engine-1", "exp/roll-hiring", "", rhA, rhB, rhShell, editNvim),
		wtree("/dev/dotfiles", "dotfiles", "main", "", cur, dotShell, editAgent),
	}
	wts[4].Current = true
	return &state.Snapshot{CurrentID: "$1", CurrentPane: cur.ID,
		Sessions: []*state.Session{misc, content, dot}, Worktrees: wts, Now: now}
}

func newWTTest(t *testing.T) (model, *fakeActions) {
	f := &fakeActions{next: wtFixture()}
	m := resize(newModel(f, wtFixture(), nil), 120, 36)
	return send(t, m, "ctrl+w"), f
}

func rowRoot(m model) string {
	if t := m.worktree(); t != nil {
		return t.Root
	}
	return ""
}

func matchRoots(m model) []string {
	var out []string
	for _, i := range m.matches {
		out = append(out, m.rows[i].RowID())
	}
	return out
}

// wtRows renders the fixture's worktree rows with "ain" highlighted and
// the cursor on roll-hiring, abbreviated or in full-repo mode.
func wtRows(w int, full bool) []string {
	snap := wtFixture()
	m := newModel(&fakeActions{}, snap, nil)
	fullW := 0
	if full {
		fullW = m.repoW
	}
	mm := newMatcher()
	var lines []string
	for i, wt := range snap.Worktrees {
		_, pos := mm.match("ain", rowLabel(wt))
		lines = append(lines, renderRow(newWorktreeRow(wt, pos, m.badges[wt.Repo], fullW), 0, w, i == 3, now))
	}
	return lines
}

func TestGoldenWorktreeRows(t *testing.T) {
	for _, w := range widths {
		for _, full := range []bool{false, true} {
			name := fmt.Sprintf("wt_rows_%d", w)
			if full {
				name = fmt.Sprintf("wt_rows_full_%d", w)
			}
			lines := wtRows(w, full)
			checkWidths(t, name, lines, w)
			golden(t, name, plain(lines))
			if w == 120 {
				golden(t, name+"_styled", strings.Join(lines, "\n")+"\n")
			}
		}
	}
}

// A worktree row is the gutter, the 2-column badge on its repo's shade, a
// space and the label, with no repo column. Full-repo mode widens every
// badge to the longest repo name, keeps the branch label aligned, and
// drops the agents section but not the status chips (D76, D78).
func TestWorktreeRowBadges(t *testing.T) {
	const w = 120
	snap := wtFixture()
	badges := newModel(&fakeActions{}, snap, nil).badges
	short, full := wtRows(w, false), wtRows(w, true)
	for i, wt := range snap.Worktrees {
		b := badges[wt.Repo]
		label := wt.Branch
		if wt.Detached() {
			label = wt.Head
		}
		got := ansi.Strip(short[i])
		if !strings.HasPrefix(got[len("▌"):], " "+b.code+" "+label) && !strings.HasPrefix(got, "  "+b.code+" "+label) {
			t.Errorf("row %d: %q", i, got)
		}
		if !strings.Contains(short[i], bg(b.bg)) || !strings.Contains(full[i], bg(b.bg)) {
			t.Errorf("row %d: badge shade %s missing", i, b.bg)
		}
		if strings.Contains(got, wt.Repo) {
			t.Errorf("row %d still shows the repo name: %q", i, got)
		}
		if !strings.Contains(got, botIcon) {
			t.Errorf("row %d lacks its agents section: %q", i, got)
		}
		f := ansi.Strip(full[i])
		if col(f, label) != 2+len("content-engine-1")+1 || !strings.Contains(f, wt.Repo) {
			t.Errorf("full row %d: label at %d: %q", i, col(f, label), f)
		}
		if strings.Contains(f, botIcon) || strings.Contains(f, "│") {
			t.Errorf("full row %d keeps the agents section: %q", i, f)
		}
		if n := len(aggregate(wt.Panes, rowOrder)); n > 0 && !strings.Contains(f, stateIcon[state.StateWorking]) &&
			!strings.Contains(f, stateIcon[state.StateDone]) && !strings.Contains(f, stateIcon[state.StateAwaiting]) {
			t.Errorf("full row %d lost its chips: %q", i, f)
		}
	}
	// The full badge is truncated at repoFullMaxW.
	long := wtree("/dev/x", "a-repository-name-longer-than-the-cap", "main", "")
	r := newWorktreeRow(long, nil, repoBadge{code: "ar", fg: cText, bg: cSurface2}, repoFullMaxW)
	if r.repo != "a-repository-name-longe…" || width(r.repo) != repoFullMaxW {
		t.Errorf("long repo badge = %q", r.repo)
	}
}

func TestAssignRepoBadges(t *testing.T) {
	type want struct{ code, bg, fg string }
	tests := []struct {
		name  string
		repos []string
		want  map[string]want
	}{
		{"distinct first two", []string{"yap-trial", "dotfiles", "search-primitives", "content-engine-1"}, map[string]want{
			"content-engine-1":  {"co", cSurface2, cText},
			"dotfiles":          {"do", cOverlay0, cText},
			"search-primitives": {"se", cOverlay1, cCrust},
			"yap-trial":         {"ya", cOverlay2, cCrust},
		}},
		{"conflicts fall to initials then pairs", []string{"content-engine-2", "co", "content-engine-1"}, map[string]want{
			"co":               {"co", cSurface2, cText},
			"content-engine-1": {"ce", cOverlay0, cText},
			"content-engine-2": {"cn", cOverlay1, cCrust},
		}},
		{"case and punctuation ignored", []string{"Search_Primitives", "search-primitives", ".dotfiles"}, map[string]want{
			".dotfiles":         {"do", cSurface2, cText},
			"Search_Primitives": {"se", cOverlay0, cText},
			"search-primitives": {"sp", cOverlay1, cCrust},
		}},
		{"single characters", []string{"x", "x-", "x_y"}, map[string]want{
			"x":   {"x1", cSurface2, cText},
			"x-":  {"x2", cOverlay0, cText},
			"x_y": {"xy", cOverlay1, cCrust},
		}},
		{"no letters or digits", []string{"--", "__", "a"}, map[string]want{
			"--": {"00", cSurface2, cText},
			"__": {"01", cOverlay0, cText},
			"a":  {"a1", cOverlay1, cCrust},
		}},
		{"shades wrap after six", []string{"a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1"}, map[string]want{
			"a1": {"a1", cSurface2, cText},
			"b1": {"b1", cOverlay0, cText},
			"c1": {"c1", cOverlay1, cCrust},
			"d1": {"d1", cOverlay2, cCrust},
			"e1": {"e1", cSubtext0, cCrust},
			"f1": {"f1", cSubtext1, cCrust},
			"g1": {"g1", cSurface2, cText},
			"h1": {"h1", cOverlay0, cText},
		}},
		{"duplicates count once", []string{"dotfiles", "dotfiles", "yap"}, map[string]want{
			"dotfiles": {"do", cSurface2, cText},
			"yap":      {"ya", cOverlay0, cText},
		}},
	}
	for _, tc := range tests {
		got := assignRepoBadges(tc.repos)
		if len(got) != len(tc.want) {
			t.Errorf("%s: %d badges, want %d", tc.name, len(got), len(tc.want))
		}
		for name, w := range tc.want {
			if b := got[name]; b.code != w.code || b.bg != w.bg || b.fg != w.fg {
				t.Errorf("%s: %q = %+v, want %+v", tc.name, name, b, w)
			}
		}
	}
	// Codes stay unique until every candidate is gone: r0-r9 and 00-99
	// give 110 names starting with r a code each.
	var many []string
	for i := range 110 {
		many = append(many, fmt.Sprintf("r%d", i))
	}
	seen := map[string]bool{}
	for _, b := range assignRepoBadges(many) {
		if width(b.code) != 2 {
			t.Errorf("code %q is not 2 columns", b.code)
		}
		seen[b.code] = true
	}
	if len(seen) != 110 {
		t.Errorf("%d unique codes for 110 repos", len(seen))
	}
}

// roll-hiring's cards: its two agents split the shared window (the third
// agent there belongs to content-engine-1 and gets no card), and the edit
// window, whose only agent is another worktree's, is a window card titled
// by its member nvim pane. content-engine-1 gets one window card showing
// its single member agent. Pane counts and memory stay window totals.
func TestGoldenWorktreeCards(t *testing.T) {
	snap := wtFixture()
	rh, ce1 := snap.Worktrees[3], snap.Worktrees[2]
	for _, w := range []int{80, 120} {
		lines := renderGrid(worktreeCards(rh), 0, 0, w, 10, now)
		lines = append(lines, renderGrid(worktreeCards(ce1), 0, 0, w, 5, now)...)
		checkWidths(t, "wt cards", lines, w)
		golden(t, fmt.Sprintf("wt_cards_%d", w), plain(lines))
		if w == 120 {
			golden(t, "wt_cards_120_styled", strings.Join(lines, "\n")+"\n")
		}
	}
}

func TestGoldenWorktreeInputLine(t *testing.T) {
	for _, w := range []int{30, 40, 80, 120} {
		m, _ := newWTTest(t)
		m.w = w
		all := m.renderInput()
		m = send(t, m, "m", "a", "i", "n")
		allQuery := m.renderInput()
		m = send(t, m, "backspace", "backspace", "backspace", "backspace")
		m = send(t, m, "tab", "tab") // content-engine-1
		repo := m.renderInput()
		m = send(t, m, "m", "a", "i", "n")
		query := m.renderInput()
		// A long query keeps its room: the chip truncates instead.
		m = send(t, m, "backspace", "backspace", "backspace", "backspace")
		m = send(t, m, strings.Split("exp/roll-hiring", "")...)
		long := m.renderInput()
		m = send(t, m, strings.Split("-and-more", "")...)
		longer := m.renderInput()
		lines := []string{all, allQuery, repo, query, long, longer}
		checkWidths(t, "wt input", lines, w)
		golden(t, fmt.Sprintf("wt_input_%d", w), plain(lines))
		if w == 120 {
			golden(t, "wt_input_120_styled", strings.Join(lines, "\n")+"\n")
		}
	}
}

func TestWorktreeCardMembership(t *testing.T) {
	snap := wtFixture()
	var got []string
	for _, c := range worktreeCards(snap.Worktrees[3]) {
		got = append(got, fmt.Sprintf("%s split=%v pane=%v", c.id(), c.split, c.pane != nil))
	}
	want := []string{
		"%agents.1 split=true pane=true",
		"%agents.2 split=true pane=true",
		"$1@w2-edit split=false pane=false",
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("cards\n got %v\nwant %v", got, want)
	}
	c := worktreeCards(snap.Worktrees[3])[2]
	if lines := cardContent(c, 56, true, now); ansi.Strip(lines[1]) != "nvim roll.ts" ||
		!strings.Contains(ansi.Strip(lines[2]), "2 panes") || strings.Contains(ansi.Strip(lines[2]), "claudef") {
		t.Errorf("edit window card: %q", ansi.Strip(strings.Join(lines, " / ")))
	}
	// Session mode still shows every agent.
	if n := len(sessionCards(snap.Sessions[1])); n != 4 {
		t.Errorf("content session: %d cards, want 3 split + 1", n)
	}
}

// ctrl+w switches to worktree rows with the cursor one above the current
// worktree and the last focused member pane's card, and back.
func TestWorktreeModeSwitch(t *testing.T) {
	m := resize(newModel(&fakeActions{}, wtFixture(), nil), 120, 36)
	if m.mode != modeSessions || sessionName(m) != "content" {
		t.Fatalf("opens on %v %q", m.mode, sessionName(m))
	}
	m = send(t, m, "ctrl+w")
	if m.mode != modeWorktrees || rowRoot(m) != "/dev/roll-hiring" {
		t.Fatalf("worktree mode cursor = %q", rowRoot(m))
	}
	if cardID(m) != "%agents.2" { // rhB, focused 30s ago
		t.Errorf("default card = %q", cardID(m))
	}
	if got := m.countText(); got != "5/5" {
		t.Errorf("count = %s", got)
	}
	rows := ansi.Strip(strings.Join(m.renderList(), "\n"))
	if !strings.Contains(rows, "co exp/roll-hiring") || strings.Contains(rows, "content-engine-1") {
		t.Errorf("rows:\n%s", rows)
	}
	m = send(t, m, "ctrl+n")
	if rowRoot(m) != "/dev/dotfiles" || cardID(m) != "$1@w1-picker" {
		t.Errorf("current row: %q %q", rowRoot(m), cardID(m))
	}
	m = send(t, m, "ctrl+w")
	if m.mode != modeSessions || sessionName(m) != "content" {
		t.Errorf("back to sessions: %v %q", m.mode, sessionName(m))
	}
}

func TestWorktreeDefaultCardFallback(t *testing.T) {
	clear := func(snap *state.Snapshot) {
		for _, p := range snap.Worktrees[3].Panes {
			p.FocusAt = 0
		}
	}
	snap := wtFixture()
	clear(snap)
	m := send(t, resize(newModel(&fakeActions{}, snap, nil), 120, 36), "ctrl+w")
	if cardID(m) != "%agents.1" { // active pane of the active window of attached $2
		t.Errorf("fallback = %q", cardID(m))
	}
	snap = wtFixture()
	clear(snap)
	snap.Sessions[1].Attached = false // and $1's edit window is not active
	m = send(t, resize(newModel(&fakeActions{}, snap, nil), 120, 36), "ctrl+w")
	if m.sel != 0 {
		t.Errorf("no fallback pane: sel = %d", m.sel)
	}
}

// Without a current worktree the cursor starts on the bottom row.
func TestWorktreeNoCurrent(t *testing.T) {
	snap := wtFixture()
	snap.Worktrees[4].Current = false
	m := send(t, resize(newModel(&fakeActions{}, snap, nil), 120, 36), "ctrl+w")
	if rowRoot(m) != "/dev/dotfiles" {
		t.Errorf("cursor = %q", rowRoot(m))
	}
}

func TestRepoFilterCycle(t *testing.T) {
	m, _ := newWTTest(t)
	steps := []struct {
		key, repo, count, cur string
	}{
		{"tab", "dotfiles", "1/1", "/dev/dotfiles"},
		{"tab", "content-engine-1", "3/3", "/dev/roll-hiring"},
		{"tab", "yap-trial", "1/1", "/dev/yap-trial"},
		{"tab", "", "5/5", "/dev/roll-hiring"}, // wraps to All
		{"shift+tab", "yap-trial", "1/1", "/dev/yap-trial"},
		{"shift+tab", "content-engine-1", "3/3", "/dev/roll-hiring"},
		{"shift+tab", "dotfiles", "1/1", "/dev/dotfiles"},
		{"shift+tab", "", "5/5", "/dev/roll-hiring"},
		{"shift+tab", "yap-trial", "1/1", "/dev/yap-trial"}, // wraps back
	}
	for i, st := range steps {
		m = send(t, m, st.key)
		if m.repo != st.repo || m.countText() != st.count || rowRoot(m) != st.cur {
			t.Fatalf("step %d %s: repo=%q count=%s cur=%q", i+1, st.key, m.repo, m.countText(), rowRoot(m))
		}
	}
	// The filter applies before the query.
	m = send(t, m, "tab", "tab", "tab", "m", "a", "i", "n")
	if got := matchRoots(m); !reflect.DeepEqual(got, []string{"/dev/content-engine-1"}) || m.countText() != "1/3" {
		t.Errorf("filtered query: %v %s", got, m.countText())
	}
}

func TestTabDoesNothingInSessionMode(t *testing.T) {
	m, _ := newTest(t)
	m = send(t, m, "tab", "shift+tab", "ctrl+t")
	if m.repo != "" || m.fullRepo || m.query.Value() != "" || sessionName(m) != "dotfiles-agents-with-a-very-long-session-name-for-truncation" {
		t.Errorf("session mode: repo=%q full=%v query=%q cur=%q", m.repo, m.fullRepo, m.query.Value(), sessionName(m))
	}
}

// Search matches branches (or a detached commit id) in either repo view,
// never re-ranks, and always highlights the label.
func TestWorktreeSearch(t *testing.T) {
	m, _ := newWTTest(t)
	m = send(t, m, "m", "a", "i", "n")
	want := []string{"/dev/yap-trial", "/dev/content-engine-1", "/dev/dotfiles"}
	if got := matchRoots(m); !reflect.DeepEqual(got, want) {
		t.Errorf("main: %v", got)
	}
	if !strings.Contains(strings.Join(m.renderList(), ""), fg(matchFg)) {
		t.Error("branch labels should highlight matches")
	}
	m = send(t, m, "ctrl+t")
	if got := matchRoots(m); !reflect.DeepEqual(got, want) {
		t.Errorf("main in full-repo mode: %v", got)
	}
	list := strings.Join(m.renderList(), "\n")
	if !strings.Contains(list, fg(matchFg)) || !strings.Contains(ansi.Strip(list), "content-engine-1 main") {
		t.Errorf("full-repo mode: %q", ansi.Strip(list))
	}
	// Neither a directory nor a repo name is searched.
	m = send(t, m, "backspace", "backspace", "backspace", "backspace", "y", "a", "p", "-")
	if len(m.matches) != 0 {
		t.Errorf("repo name matched: %v", matchRoots(m))
	}
	m = send(t, m, "backspace", "backspace", "backspace", "backspace", "1", "a", "2", "b")
	if got := matchRoots(m); !reflect.DeepEqual(got, []string{"/dev/content-engine-5"}) {
		t.Errorf("commit id: %v", got)
	}
	m = send(t, m, "ctrl+t")
	if m.fullRepo {
		t.Error("ctrl+t should toggle back")
	}
}

// Full-repo mode is off on open and survives mode switches within a run.
func TestFullRepoModeKept(t *testing.T) {
	m, _ := newWTTest(t)
	if m.fullRepo || strings.Contains(ansi.Strip(strings.Join(m.renderList(), "\n")), "yap-trial") {
		t.Fatal("full-repo mode should start off")
	}
	m = send(t, m, "ctrl+t", "ctrl+w")
	if !m.fullRepo {
		t.Fatal("full-repo mode lost in session mode")
	}
	if list := ansi.Strip(strings.Join(m.renderList(), "\n")); !strings.Contains(list, botIcon) {
		t.Errorf("session rows changed: %q", list)
	}
	m = send(t, m, "ctrl+w")
	list := ansi.Strip(strings.Join(m.renderList(), "\n"))
	if !m.fullRepo || !strings.Contains(list, "yap-trial        main") || strings.Contains(list, botIcon) {
		t.Errorf("back in worktree mode: full=%v\n%s", m.fullRepo, list)
	}
}

// The filter chip follows the query on the left; a repo's chip takes its
// badge shade. Prompts and errors show no chip.
func TestFilterChipPlacement(t *testing.T) {
	m, _ := newWTTest(t)
	m = send(t, m, "m", "a")
	got := ansi.Strip(m.renderInput())
	if !strings.HasPrefix(got, "  ma   All ") || !strings.HasSuffix(got, "3/5   ") {
		t.Errorf("All chip: %q", got)
	}
	m = send(t, m, "tab", "tab") // content-engine-1
	line := m.renderInput()
	if !strings.HasPrefix(ansi.Strip(line), "  ma   content-engine-1 ") {
		t.Errorf("repo chip: %q", ansi.Strip(line))
	}
	b := m.badges["content-engine-1"]
	if !strings.Contains(line, bg(b.bg)) || !strings.Contains(line, fg(b.fg)) {
		t.Errorf("repo chip should use the badge shade %s: %q", b.bg, line)
	}
	m = send(t, m, "tab") // yap-trial
	if b := m.badges["yap-trial"]; b.bg != cOverlay1 || !strings.Contains(m.renderInput(), bg(b.bg)) {
		t.Errorf("yap-trial chip: %+v %q", b, m.renderInput())
	}
	m = send(t, m, "ctrl+a", "C")
	if strings.Contains(m.renderInput(), bg(m.badges["yap-trial"].bg)) {
		t.Errorf("prompt shows the chip: %q", ansi.Strip(m.renderInput()))
	}
	m = send(t, m, "esc")
	m.err = errFake
	if got := ansi.Strip(m.renderInput()); strings.Contains(got, "yap-trial") {
		t.Errorf("error shows the chip: %q", got)
	}
}

func TestWorktreeModeKeepsFilterAndQuery(t *testing.T) {
	m, _ := newWTTest(t)
	m = send(t, m, "tab", "tab", "i")
	m = send(t, m, "ctrl+w")
	if m.mode != modeSessions || m.query.Value() != "i" || m.repo != "content-engine-1" {
		t.Fatalf("sessions: query=%q repo=%q", m.query.Value(), m.repo)
	}
	// No filter in session mode, and no indicator.
	if m.countText() != "2/3" || strings.Contains(ansi.Strip(m.renderInput()), "content-engine-1") {
		t.Errorf("session count %s, input %q", m.countText(), ansi.Strip(m.renderInput()))
	}
	m = send(t, m, "ctrl+w")
	if m.query.Value() != "i" || m.repo != "content-engine-1" || m.countText() != "2/3" {
		t.Errorf("back: query=%q repo=%q count=%s", m.query.Value(), m.repo, m.countText())
	}
	// With a query the cursor is the bottom match.
	if rowRoot(m) != "/dev/roll-hiring" || cardID(m) != "%agents.2" {
		t.Errorf("cursor %q card %q", rowRoot(m), cardID(m))
	}
}

func TestWorktreeActions(t *testing.T) {
	m, f := newWTTest(t) // roll-hiring, card %agents.2 (session $2)
	m = send(t, m, "ctrl+a", "R")
	m = send(t, m, "ctrl+a", "Q")
	if m.pending != promptNone || len(f.calls) != 0 {
		t.Fatalf("R/Q should do nothing: pending=%v calls=%v", m.pending, f.calls)
	}
	m = send(t, m, "ctrl+a", "c", "enter")
	m = send(t, m, "ctrl+a", "C")
	if m.prompt.Value() != "roll-hiring" {
		t.Errorf("new session default = %q", m.prompt.Value())
	}
	m = send(t, m, "enter")
	m = send(t, m, "ctrl+a", "r", "ctrl+u", "x", "enter")
	m = send(t, m, "ctrl+a", "q")
	want := []string{
		`new-window $2 "" -c /dev/roll-hiring`,
		"new-session roll-hiring -c /dev/roll-hiring",
		"rename-window $2@w1-agents x",
		"kill-pane %agents.2",
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Errorf("calls:\n%v\nwant\n%v", f.calls, want)
	}

	// Enter on an unmatched query creates nothing and stays.
	m, f = newWTTest(t)
	m = send(t, m, "z", "z", "z", "enter")
	if m.quitting || len(f.calls) != 0 {
		t.Errorf("unmatched enter: quitting=%v calls=%v", m.quitting, f.calls)
	}
	// C-a C without a row does nothing either.
	m = send(t, m, "ctrl+a", "C")
	if m.pending != promptNone {
		t.Error("C-a C without a worktree should not prompt")
	}

	// Enter switches to the card's session, window and pane.
	m, f = newWTTest(t)
	m = send(t, m, "enter")
	if !m.quitting || len(f.calls) != 1 || f.calls[0] != "switch $2 $2@w1-agents %agents.2" {
		t.Errorf("enter: %v", f.calls)
	}
	// A window card of another session keeps its window's active pane.
	m, f = newWTTest(t)
	m = send(t, m, "ctrl+j", "enter")
	if len(f.calls) != 1 || f.calls[0] != "switch $1 $1@w2-edit -" {
		t.Errorf("window card enter: %v", f.calls)
	}
}

// A reload keeps the worktree row by root and the card by id, even when the
// rows reorder; a filter on a repo that is gone goes back to All.
func TestWorktreeReload(t *testing.T) {
	m, f := newWTTest(t)
	m = send(t, m, "ctrl+p") // content-engine-1
	if rowRoot(m) != "/dev/content-engine-1" || cardID(m) != "$2@w1-agents" {
		t.Fatalf("setup %q %q", rowRoot(m), cardID(m))
	}
	next := wtFixture()
	w := next.Worktrees
	next.Worktrees = []*state.Worktree{w[2], w[0], w[1], w[3], w[4]}
	f.next = next
	m = send(t, m, "ctrl+a", "c", "enter")
	if rowRoot(m) != "/dev/content-engine-1" || cardID(m) != "$2@w1-agents" || m.mode != modeWorktrees {
		t.Errorf("after reload: %q %q", rowRoot(m), cardID(m))
	}

	m = send(t, m, "tab", "tab", "tab") // yap-trial
	next = wtFixture()
	next.Worktrees = next.Worktrees[1:]
	f.next = next
	m = send(t, m, "ctrl+a", "c", "enter")
	if m.repo != "" || m.countText() != "4/4" {
		t.Errorf("gone repo: %q %s", m.repo, m.countText())
	}
}
