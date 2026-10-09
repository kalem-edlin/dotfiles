package ui

import (
	"fmt"
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"

	"agentpicker/state"
)

// fg and bg are the truecolor SGR parameters paint emits for a hex colour.
func fg(hex string) string {
	c := parseHex(hex)
	return fmt.Sprintf("38;2;%d;%d;%d", int(c.r), int(c.g), int(c.b))
}

func bg(hex string) string {
	c := parseHex(hex)
	return fmt.Sprintf("48;2;%d;%d;%d", int(c.r), int(c.g), int(c.b))
}

// manyPanes is a session with one window of n agent panes.
func manyPanes(n int) *state.Session {
	var panes []*state.Pane
	for i := range n {
		panes = append(panes, agent("claude", fmt.Sprintf("task %d", i+1), state.StateWorking, 60, 100))
	}
	panes[0].Active = true
	return sess("$9", "many", now, win(1, "work", true, panes...))
}

// col returns the display column where sub starts in plain text line.
func col(line, sub string) int {
	i := strings.Index(line, sub)
	if i < 0 {
		return -1
	}
	return width(line[:i])
}

// Rows have three right-hand sections (D55): the chips, then the agents
// and memory at fixed columns whatever the chip set, divided by `│` rules.
func TestSessionRowSections(t *testing.T) {
	const w, memW = 120, 11
	var agentsCol, memCol = -1, -1
	for i, s := range fixture().Sessions {
		r := newSessionRow(s, nil)
		line := renderSessionRow(r, memW, w, i == 3, now)
		got := ansi.Strip(line)
		if width(line) != w {
			t.Fatalf("row %d is %d columns", i, width(line))
		}
		if ansi.Strip(ansi.Cut(line, 1, 2+width(r.name))) != " "+r.name {
			t.Errorf("row %d: name not at the left: %q", i, got)
		}
		// Memory is right-aligned in its fixed cell, one space from the edge.
		if !strings.HasSuffix(got, strings.Repeat(" ", memW-width(r.mem))+r.mem+" ") {
			t.Errorf("row %d: memory cell: %q", i, got)
		}
		cut := ansi.Strip(ansi.Cut(line, w-1-memW-sepW-agentsW, w-1-memW-sepW))
		if want := ansi.Strip(agentsCell(r.agents, r.agentsAt, now, panelBg, false)); cut != want {
			t.Errorf("row %d: agents section %q, want %q", i, cut, want)
		}
		if n := strings.Count(got, "│"); n != 2 {
			t.Errorf("row %d: %d separators: %q", i, n, got)
		}
		// Both separators at the same columns on every row.
		a, m := col(got, " │ "), strings.LastIndex(got, " │ ")
		m = width(got[:m])
		if i == 0 {
			agentsCol, memCol = a, m
		} else if a != agentsCol || m != memCol {
			t.Errorf("row %d: separators at %d,%d, want %d,%d: %q", i, a, m, agentsCol, memCol, got)
		}
		// The separators use the rule colour, the agents and memory have no
		// chip background.
		if !strings.Contains(line, fg(cSurface2)) {
			t.Errorf("row %d: separator colour missing", i)
		}
	}
}

// The agents and memory columns line up across rows with different chip
// sets; a session without agents shows 0 and no age.
func TestRowAlignmentAndAgents(t *testing.T) {
	const w, memW = 140, 11
	snap := fixture()
	rows := map[string]string{}
	for _, s := range snap.Sessions {
		rows[s.Name] = ansi.Strip(renderSessionRow(newSessionRow(s, nil), memW, w, false, now))
	}
	botCols := map[int]bool{}
	for name, r := range rows {
		botCols[col(r, botIcon)] = true
		if width(r) != w {
			t.Errorf("%s: %d columns", name, width(r))
		}
	}
	if len(botCols) != 1 {
		t.Errorf("agents glyph at different columns: %v", botCols)
	}
	if got := rows["infra"]; !strings.Contains(got, " "+botIcon+" 0      ") || strings.Contains(got, stateIcon[state.StateWorking]) {
		t.Errorf("no-agent row: %q", got)
	}
	// funnel: 3 agents (working 120s, done 40s, idle 2d); newest change 40s.
	if got := rows["roll-web-funnel-changes"]; !strings.Contains(got, " "+botIcon+" 3 40s") {
		t.Errorf("funnel agents: %q", got)
	}
	// Memory cells end at the same column too.
	for name, r := range rows {
		if !strings.HasSuffix(r, " ") || width(r) != w {
			t.Errorf("%s: bad right edge %q", name, r)
		}
	}
}

// Chips go Working, Awaiting, Done, only when the count is above zero; no
// Idle chip on rows. Row chips show icons (D55).
func TestRowChipOrderAndIcons(t *testing.T) {
	s := sess("$7", "mix", now, win(1, "a", true,
		active(agent("claude", "a", state.StateDone, 600, 1)),
		agent("claude", "b", state.StateWorking, 240, 1),
		agent("claude", "c", state.StateWorking, 120, 1),
		agent("claude", "d", state.StateAwaiting, 60, 1),
		agent("pi", "e", state.StateIdle, 30, 1)))
	r := newSessionRow(s, nil)
	row := ansi.Strip(renderSessionRow(r, 5, 140, false, now))
	iw := col(row, "2 "+stateIcon[state.StateWorking]+" 2m")
	ww := col(row, "1 "+stateIcon[state.StateAwaiting]+" 1m")
	dw := col(row, "1 "+stateIcon[state.StateDone]+" 10m")
	if iw < 0 || ww < iw || dw < ww {
		t.Errorf("chip order wrong (working %d awaiting %d done %d): %q", iw, ww, dw, row)
	}
	if strings.Contains(row, "Working") || strings.Contains(row, "Idle") || strings.Contains(row, stateIcon[state.StateIdle]) {
		t.Errorf("word or idle chip on a row: %q", row)
	}
	if !strings.Contains(row, " "+botIcon+" 5 30s") {
		t.Errorf("agents section: %q", row)
	}
	// Zero counts are omitted.
	only := newSessionRow(sess("$8", "one", now, win(1, "a", true, active(agent("claude", "a", state.StateDone, 60, 1)))), nil)
	if len(only.chips) != 1 || only.chips[0].state != state.StateDone {
		t.Errorf("chips = %+v", only.chips)
	}
}

func TestListShowsSixRows(t *testing.T) {
	m, _ := newTest(t)
	rows := m.renderList()
	if len(rows) != listRows || listRows != 6 {
		t.Fatalf("list has %d rows, want 6", len(rows))
	}
	for i, s := range m.snap.Sessions {
		if !strings.Contains(ansi.Strip(rows[i]), s.Name[:min(8, len(s.Name))]) {
			t.Errorf("row %d should show %s: %q", i, s.Name, ansi.Strip(rows[i]))
		}
	}

	// Fewer matches: the empty rows sit at the top.
	m = send(t, m, "r", "o", "l", "l")
	rows = m.renderList()
	for i, r := range rows {
		blank := strings.TrimSpace(ansi.Strip(r)) == ""
		if blank != (i < 3) {
			t.Errorf("query roll, row %d blank=%v: %q", i, blank, ansi.Strip(r))
		}
	}

	// More sessions than rows: 6 show, bottom-anchored, and the list
	// scrolls with the cursor.
	snap := fixture()
	extra := fixture().Sessions[:3]
	for i, s := range extra {
		s.ID, s.Name = fmt.Sprintf("$x%d", i), fmt.Sprintf("extra-%d", i)
	}
	snap.Sessions = append(extra, snap.Sessions...)
	m = resize(newModel(&fakeActions{}, snap, nil), 120, 36)
	if len(m.renderList()) != 6 || m.top != 3 {
		t.Errorf("9 sessions: %d rows, top %d, want 6 rows from 3", len(m.renderList()), m.top)
	}
	m = send(t, m, "up", "up", "up", "up", "up", "up")
	if m.top != 1 || !strings.Contains(ansi.Strip(m.renderList()[0]), "extra-1") {
		t.Errorf("after scrolling up: top %d, first row %q", m.top, ansi.Strip(m.renderList()[0]))
	}
}

// Two columns of half the width each, or one full-width column under 61
// columns (D41).
func TestGridColumnsRender(t *testing.T) {
	cards := buildCards(fixture().Sessions[3])
	for _, tt := range []struct{ w, cols int }{{60, 1}, {61, 2}, {180, 2}} {
		lines := renderGrid(cards, 0, 0, tt.w, 5, now)
		top := ansi.Strip(lines[0])
		if n := strings.Count(top, "╭"); n != tt.cols {
			t.Errorf("width %d: %d cards across, want %d: %q", tt.w, n, tt.cols, top)
		}
		if !strings.HasPrefix(top, "╭") || !strings.HasSuffix(top, "╮") {
			t.Errorf("width %d: cards should span the full width: %q", tt.w, top)
		}
	}
}

// At most 3 full card rows, then the top border and first content line of
// the next row as a cue, only when such a row exists (D36).
func TestGridPeek(t *testing.T) {
	const w = 120
	isTop := func(l string) bool { return strings.HasPrefix(ansi.Strip(l), "╭") }
	isBottom := func(l string) bool { return strings.HasPrefix(ansi.Strip(l), "╰") }
	blank := func(l string) bool { return strings.TrimSpace(ansi.Strip(l)) == "" }

	// 9 cards: 5 rows, 3 full and a peek of the 4th.
	cards := buildCards(manyPanes(9))
	lines := renderGrid(cards, 0, 0, w, 30, now)
	for r := range 3 {
		if !isTop(lines[r*5]) || !isBottom(lines[r*5+4]) {
			t.Errorf("row %d not drawn in full", r)
		}
	}
	if !isTop(lines[15]) || !strings.Contains(ansi.Strip(lines[16]), "1.7 work") {
		t.Errorf("peek missing: %q / %q", ansi.Strip(lines[15]), ansi.Strip(lines[16]))
	}
	for i, l := range lines[17:] {
		if !blank(l) {
			t.Errorf("line %d after the peek should be blank: %q", 17+i, ansi.Strip(l))
		}
	}

	// Scrolled to the last rows: 3 full rows, nothing below, no peek.
	lines = renderGrid(cards, 8, 2, w, 30, now)
	if !isBottom(lines[14]) || !blank(lines[15]) || !blank(lines[16]) {
		t.Errorf("no peek expected at the end: %q", ansi.Strip(lines[15]))
	}

	// Exactly 3 rows: no peek.
	lines = renderGrid(buildCards(manyPanes(6)), 0, 0, w, 30, now)
	if !isBottom(lines[14]) || !blank(lines[15]) {
		t.Errorf("no peek expected with 3 rows: %q", ansi.Strip(lines[15]))
	}

	// Room for 3 rows but not the peek: 2 full rows give way to it.
	lines = renderGrid(cards, 0, 0, w, 15, now)
	if !isBottom(lines[9]) || !isTop(lines[10]) || !blank(lines[12]) {
		t.Errorf("short grid should show 2 rows and a peek:\n%s", plain(lines))
	}

	// The model never leaves the selection in the peek.
	m := resize(newModel(&fakeActions{}, &state.Snapshot{Sessions: []*state.Session{manyPanes(9)}, Now: now}, nil), w, 45)
	m.sel, m.gridTop = 0, 0
	m = send(t, m, "ctrl+j", "ctrl+j", "ctrl+j") // row 3, the peek row at top 0
	if m.gridTop != 1 {
		t.Errorf("gridTop = %d, want 1", m.gridTop)
	}
	screen := strings.Split(m.render(), "\n")
	if !strings.Contains(ansi.Strip(screen[11]), "1.7 work") || !isBottom(screen[14]) {
		t.Errorf("selected row not in full:\n%s", plain(screen[:18]))
	}
}

// A rule above and below the input line, in the card border colour; no
// "+T" by the count (D44, D47).
func TestInputRules(t *testing.T) {
	m, _ := newTest(t)
	lines := strings.Split(m.render(), "\n")
	h := len(lines)
	if h != 36 {
		t.Fatalf("%d lines", h)
	}
	for _, i := range []int{h - 3, h - 1} {
		if got := ansi.Strip(lines[i]); got != strings.Repeat("─", 120) {
			t.Errorf("line %d is not a rule: %q", i, got)
		}
		if !strings.Contains(lines[i], fg("#585b70")) {
			t.Errorf("rule %d not in #585b70", i)
		}
	}
	input := ansi.Strip(lines[h-2])
	if !strings.Contains(input, "6/6") || strings.Contains(input, "+T") {
		t.Errorf("input line = %q", input)
	}
	if !strings.Contains(ansi.Strip(lines[h-4]), "dotfiles") {
		t.Errorf("the list should sit right above the top rule: %q", ansi.Strip(lines[h-4]))
	}
}

// Every status chip has darker-shade text and a lighter age, on the D60
// pastel backgrounds.
func TestChipColours(t *testing.T) {
	want := map[state.State]string{
		state.StateDone:     "#a6e3a1",
		state.StateWorking:  "#89b4fa",
		state.StateAwaiting: "#fab387",
		state.StateIdle:     "#6c7086",
	}
	text := map[state.State]string{
		state.StateDone:     "#465f44",
		state.StateWorking:  "#394c69",
		state.StateAwaiting: "#694b39",
		state.StateIdle:     "#2d2f38",
	}
	age := map[state.State]string{
		state.StateDone:     "#719b6f",
		state.StateWorking:  "#5e7bac",
		state.StateAwaiting: "#ac7a5c",
		state.StateIdle:     "#4a4d5c",
	}
	for st, b := range want {
		c := aggChip(agg{state: st, count: 2, at: now - 300}, now, true)
		for _, part := range []string{fg(text[st]), fg(age[st]), bg(b)} {
			if !strings.Contains(c, part) {
				t.Errorf("%s chip lacks %s: %q", st, part, c)
			}
		}
		if strings.Contains(c, fg("#ffffff")) {
			t.Errorf("%s chip has white text", st)
		}
		p := agent("claude", "x", st, 300, 1)
		if s := statusChip(p, now, true); !strings.Contains(s, fg(text[st])) || !strings.Contains(s, fg(age[st])) ||
			strings.Contains(s, fg(cBase)) {
			t.Errorf("%s card chip: %q", st, s)
		}
		// Without an age there is no dim part.
		if c := aggChip(agg{state: st, count: 1}, now, true); strings.Contains(c, fg(age[st])) {
			t.Errorf("%s chip without age has an age colour", st)
		}
	}
	if c := chipColored("3 panes", cText, panesChipBg, true); !strings.Contains(c, fg(cText)) {
		t.Errorf("panes chip should keep light text: %q", c)
	}
}

// Card memory is plain text with no cell background (D55).
func TestCardMemoryPlain(t *testing.T) {
	p := agent("claude", "x", state.StateWorking, 60, 610)
	c := card{win: win(1, "w", true, p), pane: p}
	third := cardContent(c, 50, true, now)[2]
	if !strings.HasSuffix(ansi.Strip(third), " 610M") || strings.HasSuffix(ansi.Strip(third), " 610M ") {
		t.Errorf("card memory: %q", ansi.Strip(third))
	}
	if strings.Contains(cardMem("610M", true), "48;2;") {
		t.Errorf("card memory has a background")
	}
}

// Window with two agents: one split card per agent in pane order, headed
// W.P, sharing the window pane count and memory; the other windows get one
// card each (D51, D52, D58).
func TestSplitCards(t *testing.T) {
	s := fixture().Sessions[3] // funnel
	cards := buildCards(s)
	if len(cards) != 5 {
		t.Fatalf("%d cards, want 5", len(cards))
	}
	if !cards[0].split || !cards[1].split || cards[2].split || cards[3].split || cards[4].split {
		t.Fatalf("split flags wrong: %+v", cards)
	}
	if cards[0].pane.AgentName != "funnel step refactor" || cards[1].pane.AgentName != "copy audit" {
		t.Errorf("split cards not in pane order")
	}
	a := cardContent(cards[0], 56, true, now)
	b := cardContent(cards[1], 56, true, now)
	pa, pb := ansi.Strip(a[0]), ansi.Strip(b[0])
	if pa != "1.1 special-feature-flags" || pb != "1.2 special-feature-flags" {
		t.Errorf("headers %q %q", pa, pb)
	}
	if ansi.Strip(a[1]) != "funnel step refactor" || ansi.Strip(b[1]) != "copy audit" {
		t.Errorf("subtitles %q %q", ansi.Strip(a[1]), ansi.Strip(b[1]))
	}
	la, lb := ansi.Strip(a[2]), ansi.Strip(b[2])
	if !strings.Contains(la, "3 panes") || !strings.Contains(lb, "3 panes") ||
		!strings.HasSuffix(la, "912M") || !strings.HasSuffix(lb, "912M") {
		t.Errorf("shared chips: %q %q", la, lb)
	}
	if !strings.Contains(la, "claudef") || !strings.Contains(la, stateIcon[state.StateWorking]) ||
		!strings.Contains(lb, "pif") || !strings.Contains(lb, stateIcon[state.StateDone]) {
		t.Errorf("one agent per card: %q %q", la, lb)
	}
	if strings.Contains(la, "pif") || strings.Contains(lb, "claudef") {
		t.Errorf("a card shows two agents: %q %q", la, lb)
	}
	// Window card with one agent: header W name, agent and 1 pane.
	one := ansi.Strip(strings.Join(cardContent(cards[2], 56, true, now), "\n"))
	if !strings.HasPrefix(one, "2 notes\nrelease notes draft\n") || !strings.Contains(one, "1 pane ") && !strings.Contains(one, "1 pane\n") {
		t.Errorf("window card with one agent: %q", one)
	}
	if strings.Contains(one, "1 panes") || !strings.Contains(one, "pif") || !strings.Contains(one, stateIcon[state.StateIdle]) {
		t.Errorf("window card: %q", one)
	}
}

// A window with no agent shows its first pane's command; an empty-chat
// agent shows the dimmed placeholder (D53, D59).
func TestCardSubtitles(t *testing.T) {
	s := fixture().Sessions[3]
	cards := buildCards(s)
	build := cardContent(cards[3], 56, true, now)
	if ansi.Strip(build[0]) != "3 build" || ansi.Strip(build[1]) != "zsh" {
		t.Errorf("no-agent window card: %q %q", ansi.Strip(build[0]), ansi.Strip(build[1]))
	}
	// First pane (lowest index) decides, not the active one.
	w := win(5, "multi", true, shell("nvim", "nvim main.go", 5), active(shell("zsh", "make", 5)))
	lines := cardContent(card{win: w}, 56, true, now)
	if ansi.Strip(lines[1]) != "nvim main.go" || !strings.Contains(ansi.Strip(lines[2]), "2 panes") {
		t.Errorf("first pane command: %q / %q", ansi.Strip(lines[1]), ansi.Strip(lines[2]))
	}
	// Truncated to fit.
	if got := ansi.Strip(cardContent(card{win: w}, 8, true, now)[1]); got != "nvim ma…" {
		t.Errorf("truncated = %q", got)
	}

	e := agent("claude", "stale name", state.StateIdle, 5, 1)
	e.AgentEmpty = true
	ew := win(6, "fresh", true, active(e))
	el := cardContent(card{win: ew, pane: e}, 56, true, now)
	if ansi.Strip(el[1]) != "Empty chat" || !strings.Contains(el[1], fg(dimFg)) {
		t.Errorf("empty chat: %q", el[1])
	}
	if !strings.Contains(ansi.Strip(el[2]), "1 pane") || !strings.Contains(ansi.Strip(el[2]), "claudef") {
		t.Errorf("empty chat chips: %q", ansi.Strip(el[2]))
	}
	// Idle agent without a name falls back to the command.
	nn := agent("pi", "", state.StateIdle, 5, 1)
	nl := cardContent(card{win: win(7, "x", true, active(nn)), pane: nn}, 56, true, now)
	if ansi.Strip(nl[1]) != "pi" {
		t.Errorf("unnamed agent subtitle = %q", ansi.Strip(nl[1]))
	}
}

// The panes chip shows on every card, 1 pane included (D54).
func TestPanesChipAlways(t *testing.T) {
	w := win(1, "solo", true, active(shell("zsh", "", 3)))
	got := ansi.Strip(strings.Join(cardContent(card{win: w}, 56, true, now), "\n"))
	if !strings.Contains(got, "1 pane") || strings.Contains(got, "1 panes") {
		t.Errorf("1 pane chip: %q", got)
	}
}

// heights shrinks the grid first, then the list, then drops the rules;
// every size renders exactly h lines of w columns.
func TestHeightBudget(t *testing.T) {
	for _, tt := range []struct{ h, grid, list, rules int }{
		{45, 36, 6, 2}, {30, 21, 6, 2}, {24, 15, 6, 2}, {14, 5, 6, 2},
		{9, 0, 6, 2}, {6, 0, 3, 2}, {4, 0, 1, 2}, {3, 0, 2, 0}, {1, 0, 0, 0},
	} {
		m := resize(newModel(&fakeActions{}, fixture(), nil), 100, tt.h)
		g, l, r := m.heights()
		if g != tt.grid || l != tt.list || r != tt.rules {
			t.Errorf("h=%d: heights = %d %d %d, want %d %d %d", tt.h, g, l, r, tt.grid, tt.list, tt.rules)
		}
	}
	snaps := []*state.Snapshot{fixture(), {Sessions: []*state.Session{manyPanes(9)}, Now: now}, {}}
	for _, snap := range snaps {
		for _, w := range []int{20, 60, 61, 100, 180} {
			for h := 1; h <= 50; h++ {
				m := resize(newModel(&fakeActions{}, snap, nil), w, h)
				m = send(t, m, "ctrl+d", "ctrl+d", "ctrl+j")
				lines := strings.Split(m.render(), "\n")
				if len(lines) != h {
					t.Fatalf("%dx%d: %d lines", w, h, len(lines))
				}
				checkWidths(t, fmt.Sprintf("%dx%d", w, h), lines, w)
			}
		}
	}
}

// The agents cell starts with the bot glyph, keeps its width with and
// without an age, and dims the age below the count (bold when selected).
func TestAgentsCellStyle(t *testing.T) {
	for _, n := range []int{0, 7, 99} {
		for _, sel := range []bool{false, true} {
			c := agentsCell(n, now-36000, now, panelBg, sel)
			plain := ansi.Strip(c)
			if !strings.HasPrefix(plain, botIcon) || width(c) != agentsW {
				t.Errorf("n=%d: %q is %d columns", n, plain, width(c))
			}
		}
	}
	if got := ansi.Strip(agentsCell(7, now-36000, now, panelBg, false)); got != botIcon+" 7 10h " {
		t.Errorf("cell = %q", got)
	}
	un := agentsCell(7, now-36000, now, panelBg, false)
	if !strings.Contains(un, fg(ageFg)) {
		t.Errorf("unselected age colour: %q", un)
	}
	sel := agentsCell(7, now-36000, now, selectBg, true)
	if !strings.Contains(sel, fg(ageSelFg)) || !strings.Contains(sel, fg(cText)) || !strings.Contains(sel, "\x1b[1;") {
		t.Errorf("selected cell: %q", sel)
	}
	if strings.Contains(agentsCell(0, 0, now, panelBg, false), fg(ageFg)) {
		t.Error("no-agent cell has an age")
	}
}
