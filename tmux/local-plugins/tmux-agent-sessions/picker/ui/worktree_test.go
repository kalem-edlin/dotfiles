package ui

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"agentpicker/inspect"
	"agentpicker/state"
)

// wtOf builds a worktree; with a session it has that session's windows and
// panes, as tmuxio matches them by name (V1).
func wtOf(root, repo, branch, head string, at int64, s *state.Session) *state.Worktree {
	name := root[strings.LastIndex(root, "/")+1:]
	t := &state.Worktree{Root: root, Name: name, Repo: repo, Branch: branch, Head: head, ActiveAt: at, Session: s}
	if s != nil {
		t.Current, t.Windows, t.Panes = s.Current, s.Windows, s.Members()
		for _, p := range t.Panes {
			p.Worktree = t
		}
	}
	return t
}

// wtFixture is seven worktrees of three repos and one plain session, in
// display order (oldest at the top, the client's own last):
//
//	content-engine-9  exp/gone         missing, no session
//	yap-trial         main             no session
//	misc              (plain session, named after no worktree)
//	content-engine-7  exp/heavy        locked, no session (heavy in tests)
//	content-engine-5  detached         session $5, a done agent
//	content-engine-1  main             session $4, a working agent
//	roll-hiring       exp/roll-hiring  session $2: 2 agents and nvim in "agents", nvim in "edit"
//	dotfiles          main             session $1, current
func wtFixture() *state.Snapshot {
	cur := active(focused(5, agent("claude", "picker worktrees", state.StateWorking, 15, 800)))
	dotShell := shell("zsh", "go test ./...", 10)
	rhA := active(agent("claude", "hiring copy", state.StateAwaiting, 300, 500))
	rhB := focused(30, agent("pi", "hiring review", state.StateDone, 60, 300))
	rhShell := shell("nvim", "nvim hiring.md", 100)
	editNvim := active(shell("nvim", "nvim roll.ts", 80))
	ceA := active(agent("claude", "engine refactor", state.StateWorking, 120, 600))
	ce5 := active(agent("claude", "ce5 audit", state.StateDone, 900, 400))
	home := active(shell("zsh", "", 5))

	dot := sess("$1", "dotfiles", now, win(1, "picker", true, cur, dotShell))
	dot.Current, dot.Attached = true, true
	rh := sess("$2", "roll-hiring", now-60,
		win(1, "agents", true, rhA, rhB, rhShell),
		win(2, "edit", false, editNvim))
	rh.Attached = true
	misc := sess("$3", "misc", now-20000, win(1, "home", true, home))
	ce1 := sess("$4", "content-engine-1", now-1000, win(1, "agents", true, ceA))
	ce5s := sess("$5", "content-engine-5", now-3000, win(1, "ce5", true, ce5))

	wts := []*state.Worktree{
		wtOf("/dev/content-engine-9", "content-engine-1", "exp/gone", "", now-90000, nil),
		wtOf("/dev/yap-trial", "yap-trial", "main", "", now-50000, nil),
		wtOf("/dev/content-engine-7", "content-engine-1", "exp/heavy", "", now-5000, nil),
		wtOf("/dev/content-engine-5", "content-engine-1", "", "1a2b3c4", 0, ce5s),
		wtOf("/dev/content-engine-1", "content-engine-1", "main", "", 0, ce1),
		wtOf("/dev/roll-hiring", "content-engine-1", "exp/roll-hiring", "", 0, rh),
		wtOf("/dev/dotfiles", "dotfiles", "main", "", 0, dot),
	}
	wts[0].Missing = true
	wts[2].Locked = true
	return &state.Snapshot{CurrentID: "$1", CurrentPane: cur.ID,
		Sessions: []*state.Session{misc, ce5s, ce1, rh, dot}, Worktrees: wts, Now: now}
}

// wtRoots is the fixture's list order, top to bottom.
var wtRoots = []string{
	"/dev/content-engine-9", "/dev/yap-trial", "$3", "/dev/content-engine-7",
	"/dev/content-engine-5", "/dev/content-engine-1", "/dev/roll-hiring", "/dev/dotfiles",
}

func newWTTest(t *testing.T) (model, *fakeActions) {
	f := &fakeActions{next: wtFixture()}
	m := resize(newModel(f, wtFixture(), nil), 120, 36)
	m.heavy["/dev/content-engine-7"] = []string{"ios", "lfs"}
	return m, f
}

func rowRoot(m model) string {
	if r := m.row(); r != nil {
		return r.RowID()
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

// wtRows renders every row of the fixture with "ain" highlighted and the
// cursor on roll-hiring, abbreviated or in full-repo mode.
func wtRows(w int, full bool) []string {
	m, _ := newWTTest(nil)
	m.fullRepo = full
	mm := newMatcher()
	var lines []string
	for i, r := range m.rows {
		_, pos := mm.match("ain", rowLabel(r))
		lines = append(lines, renderRow(m.listRow(r, pos, false), m.memWidth(), w, i == 6, now))
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

// One list (V5): every worktree, with or without a session, and the plain
// session, in last-active order; the cursor one above the current row.
// ctrl-w opens the new window prompt (D104, was unbound in D86).
func TestOneList(t *testing.T) {
	m, _ := newWTTest(t)
	if got := matchRoots(m); !reflect.DeepEqual(got, wtRoots) {
		t.Fatalf("rows\n got %v\nwant %v", got, wtRoots)
	}
	if rowRoot(m) != "/dev/roll-hiring" || cardID(m) != "%agents.2" { // rhB, focused 30s ago
		t.Fatalf("cursor %q card %q", rowRoot(m), cardID(m))
	}
	if got := m.countText(); got != "8/8" {
		t.Errorf("count = %s", got)
	}
	before := strings.Join(m.renderList(), "\n")
	m = send(t, m, "ctrl+w") // new window since D104, as C-a w
	if m.pending != promptNewWindow || m.targetDir != "/dev/roll-hiring" {
		t.Errorf("ctrl+w: pending=%v dir=%q", m.pending, m.targetDir)
	}
	m = send(t, m, "esc")
	if rowRoot(m) != "/dev/roll-hiring" || m.query.Value() != "" || strings.Join(m.renderList(), "\n") != before {
		t.Errorf("ctrl+w then esc changed something: %q %q", rowRoot(m), m.query.Value())
	}
	m = send(t, m, "ctrl+n")
	if rowRoot(m) != "/dev/dotfiles" || cardID(m) != "$1@w1-picker" {
		t.Errorf("current row: %q %q", rowRoot(m), cardID(m))
	}
}

// A worktree row with a session is the session's row behind the badge:
// chips, agents and memory. One without is bare: dim badge text and label,
// its markers, nothing on the right. A plain session row keeps its name,
// lined up with the labels behind a blank badge.
func TestWorktreeRowContent(t *testing.T) {
	const w = 120
	m, _ := newWTTest(t)
	lines := wtRows(w, false)
	for i, r := range m.rows {
		got := ansi.Strip(lines[i])
		switch x := r.(type) {
		case *state.Worktree:
			b := m.badges[x.Repo]
			label := rowLabel(x)
			if col(got, label) != 5 || !strings.Contains(got, b.code+" "+label) {
				t.Errorf("row %d: %q", i, got)
			}
			if strings.Contains(got, x.Repo) {
				t.Errorf("row %d shows the repo name: %q", i, got)
			}
			if bare := x.Session == nil; bare == strings.Contains(got, botIcon) {
				t.Errorf("row %d bare=%v: %q", i, bare, got)
			}
			if x.Session == nil && (!strings.Contains(lines[i], fg(dimFg)) || strings.Contains(got, "│")) {
				t.Errorf("bare row %d not dim: %q", i, lines[i])
			}
			if x.Session != nil && !strings.Contains(got, memLabel(x.Panes)) {
				t.Errorf("row %d lacks memory %s: %q", i, memLabel(x.Panes), got)
			}
		case *state.Session:
			if col(got, x.Name) != 5 || !strings.Contains(got, botIcon) {
				t.Errorf("session row %d: %q", i, got)
			}
		}
	}
	// Full-repo mode: badges widen, labels and names stay aligned, the right
	// side keeps only the chips.
	full := wtRows(w, true)
	for i, r := range m.rows {
		got := ansi.Strip(full[i])
		at := 2 + len("content-engine-1") + 1
		if c := col(got, rowLabel(r)); c != at {
			t.Errorf("full row %d: label at %d: %q", i, c, got)
		}
		if strings.Contains(got, botIcon) || strings.Contains(got, "│") {
			t.Errorf("full row %d keeps the agents section: %q", i, got)
		}
	}
	// The full badge is truncated at repoFullMaxW.
	long := wtOf("/dev/x", "a-repository-name-longer-than-the-cap", "main", "", 0, nil)
	r := newWorktreeRow(long, nil, false, repoBadge{code: "ar", fg: cText, bg: cSurface2}, repoFullMaxW)
	if r.repo != "a-repository-name-longe…" || width(r.repo) != repoFullMaxW {
		t.Errorf("long repo badge = %q", r.repo)
	}
}

// Markers follow the label (V6): heavy symbols once probed, the lock, then
// missing. A long label truncates before a marker is dropped.
func TestRowMarkers(t *testing.T) {
	m, _ := newWTTest(t)
	lines := wtRows(120, false)
	if got := ansi.Strip(lines[3]); !strings.Contains(got, "exp/heavy ios lfs "+lockIcon) {
		t.Errorf("heavy locked row: %q", got)
	}
	if !strings.Contains(lines[3], fg(heavyFg)) {
		t.Errorf("heavy symbols colour: %q", lines[3])
	}
	if got := ansi.Strip(lines[0]); !strings.Contains(got, "exp/gone missing") || !strings.Contains(lines[0], fg(errorFg)) {
		t.Errorf("missing row: %q", lines[0])
	}
	for _, i := range []int{1, 4, 5, 6, 7} {
		if got := ansi.Strip(lines[i]); strings.Contains(got, "ios") || strings.Contains(got, "missing") || strings.Contains(got, lockIcon) {
			t.Errorf("row %d has markers: %q", i, got)
		}
	}
	// Before the probe answers there are no heavy symbols.
	delete(m.heavy, "/dev/content-engine-7")
	if got := ansi.Strip(renderRow(m.listRow(m.rows[3], nil, false), 0, 120, false, now)); strings.Contains(got, "ios") {
		t.Errorf("unprobed row: %q", got)
	}
	t7 := m.rows[3].(*state.Worktree)
	t7.Branch = strings.Repeat("long-branch-", 6)
	row := ansi.Strip(renderRow(m.listRow(t7, nil, false), 0, 40, false, now))
	if !strings.Contains(row, "… "+lockIcon) || width(row) != 40 {
		t.Errorf("narrow row: %q", row)
	}
}

func TestAssignRepoBadges(t *testing.T) {
	type want struct {
		code string
		pos  int // place in sorted order, which picks the shade
	}
	tests := []struct {
		name  string
		repos []string
		want  map[string]want
	}{
		{"distinct first two", []string{"yap-trial", "dotfiles", "search-primitives", "content-engine-1"}, map[string]want{
			"content-engine-1":  {"co", 0},
			"dotfiles":          {"do", 1},
			"search-primitives": {"se", 2},
			"yap-trial":         {"ya", 3},
		}},
		{"conflicts fall to initials then pairs", []string{"content-engine-2", "co", "content-engine-1"}, map[string]want{
			"co":               {"co", 0},
			"content-engine-1": {"ce", 1},
			"content-engine-2": {"cn", 2},
		}},
		{"case and punctuation ignored", []string{"Search_Primitives", "search-primitives", ".dotfiles"}, map[string]want{
			".dotfiles":         {"do", 0},
			"Search_Primitives": {"se", 1},
			"search-primitives": {"sp", 2},
		}},
		{"single characters", []string{"x", "x-", "x_y"}, map[string]want{
			"x":   {"x1", 0},
			"x-":  {"x2", 1},
			"x_y": {"xy", 2},
		}},
		{"no letters or digits", []string{"--", "__", "a"}, map[string]want{
			"--": {"00", 0},
			"__": {"01", 1},
			"a":  {"a1", 2},
		}},
		{"shades wrap", []string{"a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1"}, map[string]want{
			"a1": {"a1", 0},
			"b1": {"b1", 1},
			"c1": {"c1", 2},
			"d1": {"d1", 3},
			"e1": {"e1", 4},
			"f1": {"f1", 5},
			"g1": {"g1", 6},
			"h1": {"h1", 7},
		}},
		{"duplicates count once", []string{"dotfiles", "dotfiles", "yap"}, map[string]want{
			"dotfiles": {"do", 0},
			"yap":      {"ya", 1},
		}},
	}
	for _, tc := range tests {
		got := assignRepoBadges(tc.repos)
		if len(got) != len(tc.want) {
			t.Errorf("%s: %d badges, want %d", tc.name, len(got), len(tc.want))
		}
		for name, w := range tc.want {
			sh := badgeShades[w.pos%len(badgeShades)]
			if b := got[name]; b.code != w.code || b.bg != sh.bg || b.fg != sh.fg {
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

// roll-hiring's cards are its session's: two split agent cards in the
// agents window and the edit window. content-engine-1 has one window card.
// A bare row has none.
func TestGoldenWorktreeCards(t *testing.T) {
	snap := wtFixture()
	rh, ce1 := snap.Worktrees[5], snap.Worktrees[4]
	for _, w := range []int{80, 120} {
		lines := renderGrid(worktreeCards(rh), 0, 0, w, 10, now)
		lines = append(lines, renderGrid(worktreeCards(ce1), 0, 0, w, 5, now)...)
		checkWidths(t, "wt cards", lines, w)
		golden(t, fmt.Sprintf("wt_cards_%d", w), plain(lines))
		if w == 120 {
			golden(t, "wt_cards_120_styled", strings.Join(lines, "\n")+"\n")
		}
	}
	if c := worktreeCards(snap.Worktrees[1]); c != nil {
		t.Errorf("bare row cards: %v", c)
	}
	var got []string
	for _, c := range worktreeCards(rh) {
		got = append(got, fmt.Sprintf("%s split=%v", c.id(), c.split))
	}
	if want := []string{"%agents.1 split=true", "%agents.2 split=true", "$2@w2-edit split=false"}; !reflect.DeepEqual(got, want) {
		t.Errorf("cards %v", got)
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

// Without focus stamps a worktree's session falls back to its active
// window's active pane; a bare row has no card.
func TestWorktreeDefaultCardFallback(t *testing.T) {
	snap := wtFixture()
	for _, p := range snap.Worktrees[5].Panes {
		p.FocusAt = 0
	}
	m := resize(newModel(&fakeActions{}, snap, nil), 120, 36)
	if cardID(m) != "%agents.1" {
		t.Errorf("fallback = %q", cardID(m))
	}
	m = send(t, m, "ctrl+p", "ctrl+p", "ctrl+p") // content-engine-7
	if rowRoot(m) != "/dev/content-engine-7" || len(m.cards) != 0 || m.sel != 0 {
		t.Errorf("bare row: %q cards %d", rowRoot(m), len(m.cards))
	}
}

// Without a current row the cursor starts on the bottom row.
func TestWorktreeNoCurrent(t *testing.T) {
	snap := wtFixture()
	snap.Worktrees[6].Current = false
	snap.Sessions[4].Current = false
	m := resize(newModel(&fakeActions{}, snap, nil), 120, 36)
	if rowRoot(m) != "/dev/dotfiles" {
		t.Errorf("cursor = %q", rowRoot(m))
	}
}

// Tab steps through All and the repos in the order fixed at open: the
// current repo, then by most recently active worktree. A repo shows only
// its worktrees, bare ones included; plain sessions show under All.
func TestRepoFilterCycle(t *testing.T) {
	m, _ := newWTTest(t)
	if want := []string{"dotfiles", "content-engine-1", "yap-trial"}; !reflect.DeepEqual(m.repoOrder, want) {
		t.Fatalf("tab order %v", m.repoOrder)
	}
	steps := []struct {
		key, repo, count, cur string
	}{
		{"tab", "dotfiles", "1/1", "/dev/dotfiles"},
		{"tab", "content-engine-1", "5/5", "/dev/roll-hiring"},
		{"tab", "yap-trial", "1/1", "/dev/yap-trial"},
		{"tab", "", "8/8", "/dev/roll-hiring"}, // wraps to All
		{"shift+tab", "yap-trial", "1/1", "/dev/yap-trial"},
		{"shift+tab", "content-engine-1", "5/5", "/dev/roll-hiring"},
		{"shift+tab", "dotfiles", "1/1", "/dev/dotfiles"},
		{"shift+tab", "", "8/8", "/dev/roll-hiring"},
		{"shift+tab", "yap-trial", "1/1", "/dev/yap-trial"}, // wraps back
	}
	for i, st := range steps {
		m = send(t, m, st.key)
		if m.repo != st.repo || m.countText() != st.count || rowRoot(m) != st.cur {
			t.Fatalf("step %d %s: repo=%q count=%s cur=%q", i+1, st.key, m.repo, m.countText(), rowRoot(m))
		}
	}
	m = send(t, m, "tab", "tab", "tab") // content-engine-1
	want := []string{"/dev/content-engine-9", "/dev/content-engine-7", "/dev/content-engine-5", "/dev/content-engine-1", "/dev/roll-hiring"}
	if got := matchRoots(m); !reflect.DeepEqual(got, want) {
		t.Errorf("content-engine-1 rows %v", got)
	}
	// The filter applies before the query.
	m = send(t, m, "m", "a", "i", "n")
	if got := matchRoots(m); !reflect.DeepEqual(got, []string{"/dev/content-engine-1"}) || m.countText() != "1/5" {
		t.Errorf("filtered query: %v %s", got, m.countText())
	}
}

// With no worktree discovered there is no repo filter or full-repo mode.
func TestTabWithoutWorktrees(t *testing.T) {
	m, _ := newTest(t)
	m = send(t, m, "tab", "shift+tab", "ctrl+t")
	if m.repo != "" || m.fullRepo || m.query.Value() != "" || sessionName(m) != "dotfiles-agents-with-a-very-long-session-name-for-truncation" {
		t.Errorf("repo=%q full=%v query=%q cur=%q", m.repo, m.fullRepo, m.query.Value(), sessionName(m))
	}
	if strings.Contains(ansi.Strip(m.renderInput()), "All") {
		t.Errorf("filter chip without worktrees: %q", ansi.Strip(m.renderInput()))
	}
}

// Search matches branches (or a detached commit id), repo names, plain
// session names, and a worktree's directory name (its session's name)
// without a highlight. Rows never re-rank.
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
	m = send(t, m, "ctrl+t")
	m.query.SetValue("content-engine-5")
	m.refilter()
	if got := matchRoots(m); !reflect.DeepEqual(got, []string{"/dev/content-engine-5"}) || m.pos[0] != nil || m.repoHit[0] {
		t.Errorf("directory name: %v pos %v hit %v", got, m.pos, m.repoHit)
	}
	m.query.SetValue("misc")
	m.refilter()
	if got := matchRoots(m); !reflect.DeepEqual(got, []string{"$3"}) {
		t.Errorf("plain session: %v", got)
	}
	m.query.SetValue("1a2b")
	m.refilter()
	if got := matchRoots(m); !reflect.DeepEqual(got, []string{"/dev/content-engine-5"}) {
		t.Errorf("commit id: %v", got)
	}
}

// The filter chip sits between the match count and the prefix cell; a
// repo's chip takes its badge shade. Prompts and errors show no chip.
func TestFilterChipPlacement(t *testing.T) {
	m, _ := newWTTest(t)
	m = send(t, m, "m", "a")
	got := ansi.Strip(m.renderInput())
	if !strings.HasSuffix(got, " 3/8  All    ") {
		t.Errorf("All chip: %q", got)
	}
	m = send(t, m, "tab", "tab") // content-engine-1
	line := m.renderInput()
	if !strings.HasSuffix(ansi.Strip(line), " 1/5  content-engine-1    ") {
		t.Errorf("repo chip: %q", ansi.Strip(line))
	}
	b := m.badges["content-engine-1"]
	if !strings.Contains(line, bg(b.bg)) || !strings.Contains(line, fg(b.fg)) {
		t.Errorf("repo chip should use the badge shade %s: %q", b.bg, line)
	}
	m = send(t, m, "tab") // yap-trial
	if b := m.badges["yap-trial"]; b.bg != badgeShades[2].bg || !strings.Contains(m.renderInput(), bg(b.bg)) {
		t.Errorf("yap-trial chip: %+v %q", b, m.renderInput())
	}
	m = send(t, m, "ctrl+a", "s")
	if strings.Contains(m.renderInput(), bg(m.badges["yap-trial"].bg)) {
		t.Errorf("prompt shows the chip: %q", ansi.Strip(m.renderInput()))
	}
	m = send(t, m, "esc")
	m.err = errFake
	if got := ansi.Strip(m.renderInput()); strings.Contains(got, "yap-trial") {
		t.Errorf("error shows the chip: %q", got)
	}
}

// The cursor is on roll-hiring (session $2, card %agents.2) after k ups.
func wtAt(t *testing.T, ups int) (model, *fakeActions) {
	m, f := newWTTest(t)
	for range ups {
		m = send(t, m, "ctrl+p")
	}
	return m, f
}

// Keys on a worktree row with a session act on that session; on a bare
// row only C-a s and enter (open a session there) do anything; a missing
// row refuses enter; a plain session row is as session mode always was.
func TestWorktreeActions(t *testing.T) {
	m, f := wtAt(t, 0) // roll-hiring
	m = send(t, m, "ctrl+a", "R")
	if m.pending != promptRenameSession || m.prompt.Value() != "roll-hiring" {
		t.Fatalf("R: pending=%v value=%q", m.pending, m.prompt.Value())
	}
	m = send(t, m, "esc", "ctrl+a", "Q")
	if m.pending != confirmKillSession || m.target.ID != "$2" {
		t.Fatalf("Q: pending=%v", m.pending)
	}
	m = send(t, m, "n")
	m = send(t, m, "ctrl+a", "w", "enter")
	m = send(t, m, "ctrl+a", "s")
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

	// Enter switches to the card's session, window and pane; a window card
	// keeps its window's active pane.
	m, f = wtAt(t, 0)
	m = send(t, m, "enter")
	if !m.quitting || len(f.calls) != 1 || f.calls[0] != "switch $2 $2@w1-agents %agents.2" {
		t.Errorf("enter: %v", f.calls)
	}
	m, f = wtAt(t, 0)
	m = send(t, m, "ctrl+j", "enter")
	if len(f.calls) != 1 || f.calls[0] != "switch $2 $2@w2-edit -" {
		t.Errorf("window card enter: %v", f.calls)
	}

	// A bare row: no session keys, C-a s prompts its directory name, and
	// enter opens a session named after it, rooted there.
	m, f = wtAt(t, 3) // content-engine-7
	if rowRoot(m) != "/dev/content-engine-7" {
		t.Fatalf("at %q", rowRoot(m))
	}
	for _, k := range []string{"R", "Q", "w", "r", "q"} {
		if m = send(t, m, "ctrl+a", k); m.pending != promptNone {
			t.Errorf("C-a %s on a bare row prompts", k)
		}
	}
	m = send(t, m, "ctrl+a", "s")
	if m.pending != promptNewSession || m.prompt.Value() != "content-engine-7" || m.targetDir != "/dev/content-engine-7" {
		t.Errorf("bare C-a s: %v %q %q", m.pending, m.prompt.Value(), m.targetDir)
	}
	m = send(t, m, "esc", "enter")
	if !m.quitting || !reflect.DeepEqual(f.calls, []string{"create content-engine-7 -c /dev/content-engine-7"}) {
		t.Errorf("bare enter: quitting=%v %v", m.quitting, f.calls)
	}

	// A missing directory refuses enter and C-a s.
	m, f = wtAt(t, 6) // content-engine-9
	m = send(t, m, "enter")
	if m.quitting || len(f.calls) != 0 || m.err == nil || !strings.Contains(ansi.Strip(m.renderInput()), "missing") {
		t.Errorf("missing: quitting=%v calls=%v err=%v", m.quitting, f.calls, m.err)
	}
	if m = send(t, m, "ctrl+a", "s"); m.pending != promptNone {
		t.Errorf("missing C-a s prompts")
	}

	// A plain session row: enter switches, C-a s starts at home.
	m, f = wtAt(t, 4) // misc
	if rowRoot(m) != "$3" {
		t.Fatalf("at %q", rowRoot(m))
	}
	m = send(t, m, "ctrl+a", "s")
	if m.targetDir != "" || m.prompt.Value() != "" {
		t.Errorf("plain C-a s: %q %q", m.targetDir, m.prompt.Value())
	}
	m = send(t, m, "esc", "enter")
	if !reflect.DeepEqual(f.calls, []string{"switch $3 $3@w1-home -"}) {
		t.Errorf("plain enter: %v", f.calls)
	}

	// An unmatched query creates a session by that name in home.
	m, f = newWTTest(t)
	m = send(t, m, "z", "z", "z", "enter")
	if !m.quitting || !reflect.DeepEqual(f.calls, []string{"create zzz"}) {
		t.Errorf("unmatched enter: %v", f.calls)
	}
}

// A reload keeps the row by root and the card by id, even when the rows
// reorder; a filter on a repo that is gone goes back to All.
func TestWorktreeReload(t *testing.T) {
	m, f := wtAt(t, 1) // content-engine-1
	if rowRoot(m) != "/dev/content-engine-1" || cardID(m) != "$4@w1-agents" {
		t.Fatalf("setup %q %q", rowRoot(m), cardID(m))
	}
	next := wtFixture()
	w := next.Worktrees
	next.Worktrees = []*state.Worktree{w[4], w[0], w[1], w[2], w[3], w[5], w[6]}
	f.next = next
	m = send(t, m, "ctrl+a", "w", "enter")
	if rowRoot(m) != "/dev/content-engine-1" || cardID(m) != "$4@w1-agents" {
		t.Errorf("after reload: %q %q", rowRoot(m), cardID(m))
	}

	m = send(t, m, "tab", "tab", "tab") // yap-trial
	next = wtFixture()
	next.Worktrees = append(next.Worktrees[:1:1], next.Worktrees[2:]...)
	f.next = next
	m = send(t, m, "ctrl+a", "s", "enter")
	if m.repo != "" || m.countText() != "7/7" {
		t.Errorf("gone repo: %q %s", m.repo, m.countText())
	}
}

// refilter: a row matches on its branch or its repo name, the repo filter
// applies first, and rows keep their order (D82).
func TestRefilterRepoMatch(t *testing.T) {
	m, _ := newWTTest(t)
	type hit struct {
		root string
		repo bool
		pos  []int
	}
	run := func(m model) []hit {
		var out []hit
		for i, idx := range m.matches {
			out = append(out, hit{m.rows[idx].RowID(), m.repoHit[i], m.pos[i]})
		}
		return out
	}
	set := func(m model, q string) model {
		m.query.SetValue(q)
		m.refilter()
		return m
	}
	// Repo only: "yap" is in yap-trial and in no branch.
	got := run(set(m, "yap"))
	if want := []hit{{"/dev/yap-trial", true, nil}}; !reflect.DeepEqual(got, want) {
		t.Errorf("repo only: %+v", got)
	}
	// Branch only: "roll-" is in no repo name.
	got = run(set(m, "roll-"))
	if want := []hit{{"/dev/roll-hiring", false, []int{4, 5, 6, 7, 8}}}; !reflect.DeepEqual(got, want) {
		t.Errorf("branch only: %+v", got)
	}
	// Both: "exp" is in three content-engine branches, never in a repo
	// name; "hiring" is roll-hiring's branch only.
	if got := run(set(m, "exp/")); len(got) != 3 || got[0].repo {
		t.Errorf("exp/: %+v", got)
	}
	if got := run(set(m, "qqq")); len(got) != 0 {
		t.Errorf("neither: %+v", got)
	}
	// An empty query highlights nothing.
	for _, h := range run(set(m, "")) {
		if h.repo || h.pos != nil {
			t.Errorf("empty query: %+v", h)
		}
	}
	// The repo filter applies first.
	m.repo = "dotfiles"
	m = set(m, "content")
	if len(m.matches) != 0 || m.total != 1 {
		t.Errorf("filtered: %v total %d", matchRoots(m), m.total)
	}
}

// A repo-matched badge is painted in matchFg on its own background, in
// the compact and the full-repo form, and a plain one is not (D82).
func TestRepoHitBadge(t *testing.T) {
	snap := wtFixture()
	m := newModel(&fakeActions{}, snap, nil)
	wt := snap.Worktrees[4] // content-engine-1, with a session
	b := m.badges[wt.Repo]
	for _, fullW := range []int{0, m.repoW} {
		hit := renderRow(newWorktreeRow(wt, nil, true, b, fullW), 0, 120, false, now)
		plainRow := renderRow(newWorktreeRow(wt, nil, false, b, fullW), 0, 120, false, now)
		text := b.code
		if fullW > 0 {
			text = padRight(wt.Repo, fullW)
		}
		if want := paint(text, matchFg, b.bg, true); !strings.Contains(hit, want) {
			t.Errorf("fullW %d: hit badge not in matchFg: %q", fullW, hit)
		}
		if want := paint(text, b.fg, b.bg, true); !strings.Contains(plainRow, want) || strings.Contains(plainRow, fg(matchFg)) {
			t.Errorf("fullW %d: plain badge: %q", fullW, plainRow)
		}
	}
}

// A worktree row whose repo matched the query, with the branch unmatched.
func TestGoldenWorktreeRepoMatch(t *testing.T) {
	snap := wtFixture()
	m := newModel(&fakeActions{}, snap, nil)
	for _, full := range []bool{false, true} {
		fullW := 0
		if full {
			fullW = m.repoW
		}
		name := "wt_repo_match"
		if full {
			name += "_full"
		}
		var lines []string
		for _, wt := range snap.Worktrees {
			if wt.Repo == "content-engine-1" {
				lines = append(lines, renderRow(newWorktreeRow(wt, nil, true, m.badges[wt.Repo], fullW), 0, 120, false, now))
			}
		}
		checkWidths(t, name, lines, 120)
		golden(t, name, plain(lines))
	}
}

// snapOf is a worktree-only snapshot of one bare worktree per pair of repo
// and last-active stamp, in row order; the repo named cur is current.
func snapOf(cur string, rows ...[2]string) *state.Snapshot {
	snap := &state.Snapshot{Now: now}
	for i, r := range rows {
		var at int64
		fmt.Sscan(r[1], &at)
		t := wtOf(fmt.Sprintf("/dev/%s-%d", r[0], i), r[0], "main", "", at, nil)
		t.Current = r[0] == cur
		snap.Worktrees = append(snap.Worktrees, t)
	}
	return snap
}

// The tab order is the repos by last access, the current one first,
// fixed at open and carried over reloads (D83).
func TestRepoOrder(t *testing.T) {
	rows := [][2]string{{"b", "50"}, {"a", "10"}, {"c", "30"}, {"b", "5"}}
	// Row order read bottom up would give b, c, a.
	m := newModel(&fakeActions{}, snapOf("", rows...), nil)
	if want := []string{"b", "c", "a"}; !reflect.DeepEqual(m.repoOrder, want) {
		t.Errorf("by recency: %v", m.repoOrder)
	}
	m = newModel(&fakeActions{}, snapOf("a", rows...), nil)
	if want := []string{"a", "b", "c"}; !reflect.DeepEqual(m.repoOrder, want) {
		t.Errorf("current first: %v", m.repoOrder)
	}
	// Without stamps the order is first appearance from the bottom.
	m = newModel(&fakeActions{}, snapOf("", [2]string{"x", "0"}, [2]string{"y", "0"}, [2]string{"z", "0"}), nil)
	if want := []string{"z", "y", "x"}; !reflect.DeepEqual(m.repoOrder, want) {
		t.Errorf("no stamps: %v", m.repoOrder)
	}

	// Reload with the recencies turned around, one repo gone and one new.
	m = newModel(&fakeActions{}, snapOf("a", rows...), nil)
	m.repo = "c"
	m.applyReload(actionMsg{snap: snapOf("a", [2]string{"a", "1"}, [2]string{"b", "2"}, [2]string{"c", "99"})})
	if want := []string{"a", "b", "c"}; !reflect.DeepEqual(m.repoOrder, want) {
		t.Errorf("survives reload: %v", m.repoOrder)
	}
	m.applyReload(actionMsg{snap: snapOf("a", [2]string{"a", "1"}, [2]string{"d", "5"}, [2]string{"e", "7"}, [2]string{"c", "9"})})
	if want := []string{"a", "c", "e", "d"}; !reflect.DeepEqual(m.repoOrder, want) {
		t.Errorf("new appended, b dropped: %v", m.repoOrder)
	}
	m.repo = "c"
	m.applyReload(actionMsg{snap: snapOf("a", [2]string{"a", "1"}, [2]string{"d", "5"})})
	if want := []string{"a", "d"}; !reflect.DeepEqual(m.repoOrder, want) || m.repo != "" {
		t.Errorf("vanished: %v repo %q", m.repoOrder, m.repo)
	}
}

// Heavy symbols arrive after the first frame (V8): Init probes every
// present worktree once, off the UI goroutine, and a reload probes only
// new roots.
func TestHeavyAsync(t *testing.T) {
	fakeHeavy["/dev/content-engine-7"] = []string{"ios"}
	defer delete(fakeHeavy, "/dev/content-engine-7")
	m := resize(newModel(&fakeActions{next: wtFixture()}, wtFixture(), nil), 120, 36)
	if m.Init() != nil {
		t.Error("no async work without async")
	}
	m.async = true
	msg := m.heavyCmd()()
	hm, ok := msg.(heavyMsg)
	if !ok || len(hm) != 6 { // the missing one is skipped
		t.Fatalf("heavy msg %T %v", msg, msg)
	}
	nm, _ := m.Update(hm)
	m = nm.(model)
	if got := ansi.Strip(strings.Join(wtRowsOf(m), "\n")); !strings.Contains(got, "exp/heavy ios") {
		t.Errorf("rows: %s", got)
	}
	if m.heavyCmd() != nil {
		t.Error("probed twice")
	}
}

func wtRowsOf(m model) []string {
	var out []string
	for _, r := range m.rows {
		out = append(out, renderRow(m.listRow(r, nil, false), 0, 120, false, now))
	}
	return out
}

// Git state is read only when the cursor rests on a worktree row (V7):
// a move arms a timer; a stale timer does nothing; the reply fills the
// preview line above the cards, over a rule (D107). A plain session row
// has no preview line.
func TestPreviewRest(t *testing.T) {
	fakeGit["/dev/content-engine-1"] = inspect.Git{Branch: "main", Upstream: true, Ahead: 2, Behind: 1, Dirty: 3, Untracked: 1, Added: 12, Deleted: 4, Port: "3400"}
	defer delete(fakeGit, "/dev/content-engine-1")
	m, _ := newWTTest(t)
	m.async = true
	if got := ansi.Strip(m.renderPreview()); !strings.Contains(got, "/dev/roll-hiring") || !strings.Contains(got, "git …") {
		t.Errorf("before the read: %q", got)
	}
	nm, cmd := m.Update(keyMsg("ctrl+p"))
	m = nm.(model)
	if cmd == nil || rowRoot(m) != "/dev/content-engine-1" {
		t.Fatalf("no rest timer: %q", rowRoot(m))
	}
	// A stale timer (the cursor moved on) and one for another row do nothing.
	if _, c := m.Update(restMsg{seq: m.restSeq - 1, root: "/dev/content-engine-1"}); c != nil {
		t.Error("stale timer read git")
	}
	if _, c := m.Update(restMsg{seq: m.restSeq, root: "/dev/roll-hiring"}); c != nil {
		t.Error("timer for another row read git")
	}
	nm, c := m.Update(restMsg{seq: m.restSeq, root: "/dev/content-engine-1"})
	m = nm.(model)
	if c == nil {
		t.Fatal("rest did not read git")
	}
	nm, _ = m.Update(c())
	m = nm.(model)
	got := ansi.Strip(m.renderPreview())
	for _, want := range []string{"/dev/content-engine-1", "3 dirty", "1 untracked", "+12 -4", "↑2 ↓1"} {
		if !strings.Contains(got, want) {
			t.Errorf("preview lacks %q: %q", want, got)
		}
	}
	if strings.Contains(got, "main") || strings.Contains(got, "3400") {
		t.Errorf("preview shows the branch or the ports (D106, D107): %q", got)
	}
	// The line heads the grid area, a rule under it, then the cards (D107).
	screen := strings.Split(ansi.Strip(m.render()), "\n")
	if !strings.Contains(screen[0], "3 dirty") || strings.Trim(screen[1], "─") != "" || !strings.Contains(screen[2], "╭") {
		t.Errorf("preview, rule, cards expected:\n%s\n%s\n%s", screen[0], screen[1], screen[2])
	}
	if m.previewH() != 2 {
		t.Errorf("previewH %d, want 2", m.previewH())
	}
	// A zero cell is kept, dimmed, so the row keeps its shape.
	fakeGit["/dev/content-engine-1"] = inspect.Git{Branch: "main"}
	m.git["/dev/content-engine-1"] = fakeGit["/dev/content-engine-1"]
	got = ansi.Strip(m.renderPreview())
	for _, want := range []string{"0 dirty", "0 untracked", "+0 -0", "no upstream"} {
		if !strings.Contains(got, want) {
			t.Errorf("zero preview lacks %q: %q", want, got)
		}
	}
	// Read once per run: coming back arms nothing.
	nm, _ = m.Update(keyMsg("ctrl+n"))
	m = nm.(model)
	if _, c := m.Update(keyMsg("ctrl+p")); c != nil {
		t.Error("cached row re-armed")
	}
	// Missing and plain rows.
	m, _ = wtAt(t, 6)
	if got := ansi.Strip(m.renderPreview()); !strings.Contains(got, "directory missing") {
		t.Errorf("missing preview: %q", got)
	}
	m, _ = wtAt(t, 4)
	if m.previewH() != 0 || strings.Contains(ansi.Strip(m.render()), "git …") {
		t.Error("plain session row has a preview line")
	}
}

// --list prints the rows as the picker opens them and the tab order.
func TestListOutput(t *testing.T) {
	fakeHeavy["/dev/content-engine-7"] = []string{"ios", "lfs"}
	defer delete(fakeHeavy, "/dev/content-engine-7")
	var b strings.Builder
	if err := List(&fakeActions{next: wtFixture()}, &b); err != nil {
		t.Fatal(err)
	}
	want := strings.Join([]string{
		"wt\tcontent-engine-1\texp/gone\tcontent-engine-9\t-\tmissing",
		"wt\tyap-trial\tmain\tyap-trial\t-\t-",
		"sess\tmisc",
		"wt\tcontent-engine-1\texp/heavy\tcontent-engine-7\t-\tios,lfs,locked",
		"wt\tcontent-engine-1\t1a2b3c4\tcontent-engine-5\tcontent-engine-5\t-",
		"wt\tcontent-engine-1\tmain\tcontent-engine-1\tcontent-engine-1\t-",
		"wt\tcontent-engine-1\texp/roll-hiring\troll-hiring\troll-hiring\t-",
		"wt\tdotfiles\tmain\tdotfiles\tdotfiles\t-",
		"tabs\tAll\tdotfiles\tcontent-engine-1\tyap-trial",
		"",
	}, "\n")
	if b.String() != want {
		t.Errorf("got\n%s\nwant\n%s", b.String(), want)
	}
}
