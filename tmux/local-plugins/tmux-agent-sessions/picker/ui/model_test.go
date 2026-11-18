package ui

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"

	"agentpicker/state"
)

// keyMsg turns "ctrl+j", "enter", "esc", "down", "backspace", "tab",
// "shift+tab" or a single character into a key press.
func keyMsg(k string) tea.KeyPressMsg {
	named := map[string]rune{
		"enter": tea.KeyEnter, "esc": tea.KeyEscape, "down": tea.KeyDown,
		"up": tea.KeyUp, "backspace": tea.KeyBackspace, "tab": tea.KeyTab,
	}
	if c, ok := named[k]; ok {
		return tea.KeyPressMsg{Code: c}
	}
	if k == "shift+tab" {
		return tea.KeyPressMsg{Code: tea.KeyTab, Mod: tea.ModShift}
	}
	if c, ok := strings.CutPrefix(k, "ctrl+"); ok {
		return tea.KeyPressMsg{Code: rune(c[0]), Mod: tea.ModCtrl}
	}
	return tea.KeyPressMsg{Code: rune(k[0]), Text: k}
}

// send feeds keys and runs any action command the model returns, feeding
// its result back as Bubble Tea would.
func send(t *testing.T, m model, keys ...string) model {
	t.Helper()
	for _, k := range keys {
		nm, cmd := m.Update(keyMsg(k))
		m = nm.(model)
		for cmd != nil {
			msg := cmd()
			cmd = nil
			switch msg.(type) {
			case actionMsg, exitMsg, wtStatusMsg:
				nm, cmd = m.Update(msg)
				m = nm.(model)
			}
		}
	}
	return m
}

func newTest(t *testing.T) (model, *fakeActions) {
	f := &fakeActions{}
	snap, _ := f.Load()
	m := newModel(f, snap, nil)
	return resize(m, 120, 36), f
}

func sessionName(m model) string {
	if s := m.session(); s != nil {
		return s.Name
	}
	return ""
}

func cardID(m model) string {
	if c, ok := m.card(); ok {
		return c.id()
	}
	return ""
}

func TestInitialCursor(t *testing.T) {
	m, _ := newTest(t)
	if got := sessionName(m); !strings.HasPrefix(got, "dotfiles-agents") {
		t.Errorf("initial session = %q, want the previous one", got)
	}
	one := &state.Snapshot{Sessions: fixture().Sessions[5:], Now: now}
	if got := sessionName(newModel(&fakeActions{}, one, nil)); got != "dotfiles" {
		t.Errorf("single session cursor = %q", got)
	}
}

func TestRowMoves(t *testing.T) {
	m, _ := newTest(t)
	m = send(t, m, "ctrl+n")
	if got := sessionName(m); got != "dotfiles" {
		t.Errorf("ctrl+n = %q", got)
	}
	m = send(t, m, "down") // clamps at the bottom
	if got := sessionName(m); got != "dotfiles" {
		t.Errorf("down at bottom = %q", got)
	}
	m = send(t, m, "ctrl+p", "ctrl+p", "up")
	if got := sessionName(m); got != "roll-initiative-2" {
		t.Errorf("up x3 = %q", got)
	}
	m = send(t, m, "ctrl+p", "ctrl+p", "ctrl+p")
	if got := sessionName(m); got != "infra" {
		t.Errorf("top = %q", got)
	}
	if m.top != 0 {
		t.Errorf("list top = %d, want scrolled to 0", m.top)
	}
	rows := m.renderList()
	if !strings.Contains(rows[0], "infra") {
		t.Errorf("first visible row should be infra")
	}
}

func TestDefaultCardLastFocused(t *testing.T) {
	m, _ := newTest(t)
	m = send(t, m, "ctrl+p") // roll-web-funnel-changes
	// Newest @pane_focus_at is the pi pane (40s), 1.2 of
	// special-feature-flags, a split card, over the active build window.
	if got := cardID(m); got != "%special-feature-flags.2" {
		t.Errorf("default = %q", got)
	}
	// No pane stamped: the active window's active pane.
	m = send(t, m, "ctrl+p", "ctrl+p", "ctrl+p") // infra
	if got := cardID(m); got != "$1@w1-prod-ssh" {
		t.Errorf("no-focus default = %q", got)
	}
}

// The newest stamp wins across windows and split cards, agent or not, and
// an unstamped session falls back to its active pane even when that pane
// has a newer agent event.
func TestDefaultCardCases(t *testing.T) {
	funnel := func(snap *state.Snapshot) *state.Session { return snap.Sessions[3] }
	pane := func(snap *state.Snapshot, w, p int) *state.Pane { return funnel(snap).Windows[w].Panes[p] }
	cases := []struct {
		name  string
		stamp func(snap *state.Snapshot)
		want  string
	}{
		{"other split card", func(snap *state.Snapshot) {
			pane(snap, 0, 0).FocusAt = now - 5
		}, "%special-feature-flags.1"},
		{"window card in another window", func(snap *state.Snapshot) {
			pane(snap, 1, 0).FocusAt = now - 5
		}, "$4@w2-notes"},
		{"remote window", func(snap *state.Snapshot) {
			pane(snap, 3, 0).FocusAt = now - 5
		}, "$4@w4-remote-worker"},
		// A shell beside split cards has no card: its window's first.
		{"shell in a split window", func(snap *state.Snapshot) {
			pane(snap, 0, 2).FocusAt = now - 5
		}, "%special-feature-flags.1"},
		{"no stamps", func(snap *state.Snapshot) {
			for _, w := range funnel(snap).Windows {
				for _, p := range w.Panes {
					p.FocusAt = 0
				}
			}
		}, "$4@w3-build"},
	}
	for _, c := range cases {
		snap := fixture()
		c.stamp(snap)
		m := resize(newModel(&fakeActions{}, snap, nil), 120, 36)
		m = send(t, m, "ctrl+p")
		if got := cardID(m); got != c.want {
			t.Errorf("%s: default = %q, want %q", c.name, got, c.want)
		}
	}
}

// ctrl+h/l move within a grid row and ctrl+j/k between rows keeping the
// column, all stopping at the grid's edges.
func TestCardSpatialMoves(t *testing.T) {
	m, _ := newTest(t)
	m = send(t, m, "ctrl+p") // funnel: 5 cards, 2 columns at 120: [0 1] [2 3] [4]
	m.sel = 0
	steps := []struct {
		key  string
		want int
	}{
		{"ctrl+h", 0}, // left edge
		{"ctrl+k", 0}, // top row
		{"ctrl+l", 1},
		{"ctrl+l", 1}, // right edge: no wrap to the next row
		{"ctrl+j", 3}, // same column
		{"ctrl+h", 2},
		{"ctrl+h", 2},
		{"ctrl+l", 3},
		{"ctrl+j", 4}, // short last row: its last card
		{"ctrl+j", 4}, // bottom row
		{"ctrl+l", 4}, // no card to the right
		{"ctrl+k", 2}, // back up in column 0
		{"ctrl+k", 0},
	}
	for i, st := range steps {
		m = send(t, m, st.key)
		if m.sel != st.want {
			t.Fatalf("step %d %s: sel = %d, want %d", i+1, st.key, m.sel, st.want)
		}
	}
	// ctrl+d and ctrl+u no longer move.
	m = send(t, m, "ctrl+d", "ctrl+u")
	if m.sel != 0 {
		t.Errorf("ctrl+d/u moved to %d", m.sel)
	}
}

func TestCardRowToShortRow(t *testing.T) {
	snap := fixture()
	funnel := snap.Sessions[3]
	funnel.Windows = funnel.Windows[:2]
	m := resize(newModel(&fakeActions{}, snap, nil), 120, 36)
	m = send(t, m, "ctrl+p") // 3 cards (2 split + notes): rows [0 1] [2]
	m.sel = 1
	m = send(t, m, "ctrl+j")
	if m.sel != 2 {
		t.Errorf("ctrl+j onto the short row = %d", m.sel)
	}
	m = send(t, m, "ctrl+j")
	if m.sel != 2 {
		t.Errorf("ctrl+j on the last row = %d", m.sel)
	}
	funnel.Windows = funnel.Windows[:1] // 2 split cards, one row
	m = resize(newModel(&fakeActions{}, snap, nil), 120, 36)
	m = send(t, m, "ctrl+p")
	m.sel = 1
	m = send(t, m, "ctrl+j")
	if m.sel != 1 {
		t.Errorf("ctrl+j with one row = %d", m.sel)
	}
	m = resize(m, 60, 36) // 1 column: rows [0] [1]
	m.sel = 0
	m = send(t, m, "ctrl+l")
	if m.sel != 0 {
		t.Errorf("ctrl+l in one column = %d", m.sel)
	}
	m = send(t, m, "ctrl+j")
	if m.sel != 1 {
		t.Errorf("ctrl+j in one column = %d", m.sel)
	}
}

// ctrl+h moves the card selection and leaves the query alone; backspace
// still deletes.
func TestCtrlHIsNotBackspace(t *testing.T) {
	m, _ := newTest(t)
	m = send(t, m, "r", "o", "l", "l") // the cursor goes to funnel, the bottom match
	m.sel = 1
	m = send(t, m, "ctrl+h")
	if m.query.Value() != "roll" || m.sel != 0 {
		t.Errorf("ctrl+h: query=%q sel=%d", m.query.Value(), m.sel)
	}
	m = send(t, m, "backspace")
	if m.query.Value() != "rol" {
		t.Errorf("backspace: query=%q", m.query.Value())
	}
}

// The selected card's row always shows in full, never only as the peek
// under the 3 full rows (D36).
func TestGridScrollFollows(t *testing.T) {
	m, _ := newTest(t)
	m = resize(m, 40, 26) // 1 column, grid height 17: 3 rows and a peek
	m = send(t, m, "ctrl+p")
	m.sel, m.gridTop = 0, 0
	for i, want := range []int{0, 0, 1, 2, 2} { // after each ctrl+j
		m = send(t, m, "ctrl+j")
		if m.gridTop != want {
			t.Errorf("ctrl+j %d: gridTop = %d, want %d", i+1, m.gridTop, want)
		}
	}
	for i, want := range []int{2, 2, 1, 0, 0} { // after each ctrl+k
		m = send(t, m, "ctrl+k")
		if m.gridTop != want {
			t.Errorf("ctrl+k %d: gridTop = %d, want %d", i+1, m.gridTop, want)
		}
	}
}

func TestPrefixArmDisarm(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+a")
	if !m.armed {
		t.Fatal("ctrl+a should arm")
	}
	m = send(t, m, "z") // disarms and types
	if m.armed || m.query.Value() != "z" {
		t.Errorf("C-a z: armed=%v query=%q", m.armed, m.query.Value())
	}
	m = send(t, m, "backspace", "ctrl+p", "ctrl+p", "ctrl+a", "ctrl+j") // disarms and moves
	if m.armed || m.sel != 3 {
		t.Errorf("C-a ctrl+j: armed=%v sel=%d", m.armed, m.sel)
	}
	m = send(t, m, "q") // not armed: types
	if m.query.Value() != "q" || len(f.calls) != 0 {
		t.Errorf("plain q: query=%q calls=%v", m.query.Value(), f.calls)
	}
}

func TestEnter(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+p", "enter")
	if !m.quitting || len(f.calls) != 1 || f.calls[0] != "switch $4 $4@w1-special-feature-flags %special-feature-flags.2" {
		t.Errorf("split card enter: quitting=%v calls=%v", m.quitting, f.calls)
	}

	m, f = newTest(t)
	m = send(t, m, "enter")
	if len(f.calls) != 1 || f.calls[0] != "switch $5 $5@w1-main -" {
		t.Errorf("window card enter: %v", f.calls)
	}
}

func TestEnterSwitchErrorStays(t *testing.T) {
	m, f := newTest(t)
	f.err = errFake
	m = send(t, m, "enter")
	if m.quitting || m.err == nil {
		t.Errorf("switch error: quitting=%v err=%v", m.quitting, m.err)
	}
	if !strings.Contains(m.renderInput(), "boom") {
		t.Error("error not shown inline")
	}
	m = send(t, m, "a")
	if m.err != nil {
		t.Error("error should clear on the next key")
	}
}

func TestQueryAndCreate(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "R", "O", "L", "L")
	if len(m.matches) != 3 || sessionName(m) != "roll-web-funnel-changes" {
		t.Errorf("query roll: %d matches, cursor on %q", len(m.matches), sessionName(m))
	}
	if got := m.countText(); got != "3/6" {
		t.Errorf("count = %s", got)
	}
	m = send(t, m, "backspace", "backspace", "backspace", "backspace", "n", "e", "w", "-", "x")
	if len(m.matches) != 0 || len(m.cards) != 0 {
		t.Fatalf("expected no match, got %d", len(m.matches))
	}
	m = send(t, m, "enter")
	if !m.quitting || len(f.calls) != 1 || f.calls[0] != "create new-x" {
		t.Errorf("create: %v", f.calls)
	}
}

func TestEsc(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "esc")
	if !m.quitting || len(f.calls) != 0 {
		t.Error("esc should quit without actions")
	}
}

func TestPrompts(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+p") // funnel, pane 1.2 selected
	m = send(t, m, "ctrl+a", "w")
	if m.pending != promptNewWindow {
		t.Fatal("C-a w should prompt")
	}
	m = send(t, m, "enter")
	m = send(t, m, "ctrl+a", "r")
	if m.prompt.Value() != "special-feature-flags" {
		t.Errorf("rename default = %q", m.prompt.Value())
	}
	m = send(t, m, "backspace", "backspace", "backspace", "backspace", "backspace", "Z", "enter")
	m = send(t, m, "ctrl+a", "R", "2", "enter")
	m = send(t, m, "x", "ctrl+a", "s")
	if m.prompt.Value() != "x" {
		t.Errorf("new session default = %q", m.prompt.Value())
	}
	m = send(t, m, "y", "enter")
	m = send(t, m, "ctrl+a", "s", "esc") // cancelled
	if m.pending != promptNone {
		t.Error("esc should cancel the prompt")
	}
	want := []string{
		`new-window $4 ""`,
		"rename-window $4@w1-special-feature-flags special-feature-Z",
		"rename-session $4 roll-web-funnel-changes2",
		"new-session xy",
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Errorf("calls:\n%v\nwant\n%v", f.calls, want)
	}
	if f.loads != 5 { // initial + one per action
		t.Errorf("loads = %d", f.loads)
	}
	if m.quitting {
		t.Error("stay-open actions must not quit")
	}
}

func TestKillSessionConfirm(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+a", "Q")
	if m.pending != confirmKillSession || !strings.Contains(m.renderInput(), "y/N") {
		t.Fatal("C-a Q should ask")
	}
	m = send(t, m, "n")
	if len(f.calls) != 0 || m.pending != promptNone {
		t.Errorf("n should cancel: %v", f.calls)
	}
	m = send(t, m, "ctrl+a", "Q", "enter") // default is No
	if len(f.calls) != 0 {
		t.Errorf("enter should cancel: %v", f.calls)
	}
	m = send(t, m, "ctrl+a", "Q", "y")
	if len(f.calls) != 1 || f.calls[0] != "kill-session $5" {
		t.Errorf("y: %v", f.calls)
	}
}

func TestKillPaneAndWindow(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+p", "ctrl+a", "q")           // split card: the pane
	m = send(t, m, "ctrl+j", "ctrl+h", "ctrl+a", "q") // window card (notes): the window
	want := []string{"kill-pane %special-feature-flags.2", "kill-window $4@w2-notes"}
	if !reflect.DeepEqual(f.calls, want) {
		t.Errorf("calls = %v", f.calls)
	}
}

func TestReloadKeepsSelection(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+p", "ctrl+j") // funnel, window card 3 build
	if cardID(m) != "$4@w3-build" {
		t.Fatalf("setup = %q", cardID(m))
	}
	// The next snapshot drops roll-carousels-3, shifting rows, and pane
	// 1.1 of funnel, and stamps a newer focus elsewhere, which must not
	// move the selection.
	next := fixture()
	next.Sessions = append(next.Sessions[:1], next.Sessions[2:]...)
	sff := next.Sessions[2].Windows[0]
	sff.Panes = sff.Panes[1:]
	next.Sessions[2].Windows[1].Panes[0].FocusAt = now
	f.next = next
	m = send(t, m, "ctrl+a", "w", "enter")
	if sessionName(m) != "roll-web-funnel-changes" || cardID(m) != "$4@w3-build" {
		t.Errorf("after reload: %q %q", sessionName(m), cardID(m))
	}

	// The selected card disappears: same index, clamped.
	next2 := fixture()
	next2.Sessions[3].Windows = next2.Sessions[3].Windows[:2]
	f.next = next2
	m = send(t, m, "ctrl+a", "q")
	if sessionName(m) != "roll-web-funnel-changes" || m.sel != 2 {
		t.Errorf("after kill: %q sel=%d (%q)", sessionName(m), m.sel, cardID(m))
	}
}

func TestReloadAfterActionError(t *testing.T) {
	m, f := newTest(t)
	f.err = errFake
	next := fixture()
	next.Sessions = next.Sessions[:5] // the session was killed anyway
	f.next = next
	m = send(t, m, "ctrl+a", "Q", "y")
	if f.loads != 2 || len(m.snap.Sessions) != 5 {
		t.Errorf("should reload after a failed action: loads=%d sessions=%d", f.loads, len(m.snap.Sessions))
	}
	if !strings.Contains(m.renderInput(), "boom") {
		t.Error("action error not shown")
	}
}

func TestReloadFailureKeepsSnapshot(t *testing.T) {
	m, f := newTest(t)
	old := m.snap
	f.loadErr = errFake
	m = send(t, m, "ctrl+a", "q")
	if m.snap != old || m.err != errFake {
		t.Errorf("snap kept=%v err=%v", m.snap == old, m.err)
	}
}

func TestRunReturnsLoadError(t *testing.T) {
	if err := Run(&fakeActions{loadErr: errFake}); err != errFake {
		t.Errorf("Run = %v", err)
	}
}

func TestFallbackSize(t *testing.T) {
	m := newModel(&fakeActions{}, fixture(), nil)
	m = resize(m, 0, 0) // issue #1718
	if m.w != 80 || m.h != 24 {
		t.Errorf("size = %dx%d", m.w, m.h)
	}
	if n := len(strings.Split(m.render(), "\n")); n != 24 {
		t.Errorf("%d lines", n)
	}
}

// A prefilled prompt clears with ctrl-u, as in tmux's own rename prompt.
func TestPromptEditingKeys(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+p", "ctrl+a", "r", "ctrl+u", "Z", "enter")
	m = send(t, m, "ctrl+a", "R", "ctrl+w", "Y", "enter")
	want := []string{
		"rename-window $4@w1-special-feature-flags Z",
		"rename-session $4 Y",
	}
	if !reflect.DeepEqual(f.calls, want) {
		t.Errorf("calls:\n%v\nwant\n%v", f.calls, want)
	}
}

// keyState is everything a lettered action can change, for comparing the
// three forms of one letter.
func keyState(m model, f *fakeActions) string {
	return fmt.Sprintf("cur=%d sel=%d full=%v pending=%v prompt=%q label=%q dir=%q armed=%v query=%q quit=%v err=%v calls=%q",
		m.cur, m.sel, m.fullRepo, m.pending, m.prompt.Value(), m.label, m.targetDir, m.armed, m.query.Value(), m.quitting, m.err, f.calls)
}

// D104: one action table. ctrl-<letter>, C-a <letter> and C-a
// ctrl-<letter> do the same thing for every lowercase letter with an
// action, and that thing is not nothing.
func TestLetterForms(t *testing.T) {
	session := func(sel int) func(t *testing.T) (model, *fakeActions) {
		return func(t *testing.T) (model, *fakeActions) {
			m, f := newTest(t)
			m = send(t, m, "ctrl+p") // funnel: 5 cards, [0 1] [2 3] [4]
			m.sel = sel
			return m, f
		}
	}
	wtRow := func(ups int) func(t *testing.T) (model, *fakeActions) {
		return func(t *testing.T) (model, *fakeActions) { return wtAt(t, ups) }
	}
	cases := []struct {
		letter string
		setup  func(t *testing.T) (model, *fakeActions)
		check  func(m model, f *fakeActions) bool
	}{
		{"n", session(0), func(m model, _ *fakeActions) bool { return strings.HasPrefix(sessionName(m), "dotfiles-agents") }},
		{"p", session(0), func(m model, _ *fakeActions) bool { return sessionName(m) == "roll-initiative-2" }},
		{"h", session(3), func(m model, _ *fakeActions) bool { return m.sel == 2 }},
		{"l", session(0), func(m model, _ *fakeActions) bool { return m.sel == 1 }},
		{"j", session(0), func(m model, _ *fakeActions) bool { return m.sel == 2 }},
		{"k", session(2), func(m model, _ *fakeActions) bool { return m.sel == 0 }},
		{"t", wtRow(0), func(m model, _ *fakeActions) bool { return m.fullRepo }},
		{"w", session(0), func(m model, _ *fakeActions) bool { return m.pending == promptNewWindow }},
		{"s", session(0), func(m model, _ *fakeActions) bool { return m.pending == promptNewSession }},
		{"r", session(0), func(m model, _ *fakeActions) bool { return m.pending == promptRenameWindow }},
		{"q", session(0), func(_ model, f *fakeActions) bool {
			return reflect.DeepEqual(f.calls, []string{"kill-pane %special-feature-flags.1"})
		}},
		{"c", wtRow(0), func(m model, _ *fakeActions) bool {
			return m.pending == promptNewWorktree && m.label == "new worktree from main: "
		}},
		{"x", wtRow(0), func(m model, _ *fakeActions) bool { return m.pending == promptRepurpose }},
	}
	for _, c := range cases {
		forms := [][]string{{"ctrl+" + c.letter}, {"ctrl+a", c.letter}, {"ctrl+a", "ctrl+" + c.letter}}
		if c.letter == "c" {
			forms = forms[1:] // ctrl-c closes (TestCtrlCAndCreate)
		}
		var first string
		for i, keys := range forms {
			m, f := c.setup(t)
			m = send(t, m, keys...)
			got := keyState(m, f)
			if !c.check(m, f) {
				t.Errorf("%v: no effect: %s", keys, got)
			}
			if i == 0 {
				first = got
			} else if got != first {
				t.Errorf("%s forms differ:\n %v: %s\n %v: %s", c.letter, forms[0], first, keys, got)
			}
		}
	}
}

// Uppercase actions are C-a <Letter> only; C-a ctrl-<letter> is the
// lowercase action, and a bare capital types into the query.
func TestUppercaseOnlyWithPrefix(t *testing.T) {
	cases := []struct {
		upper, lower string
		ups          int
		want         promptKind
	}{
		{"C", "c", 0, promptNewWorktree},
		{"R", "r", 0, promptRenameSession},
		{"Q", "q", 0, confirmKillSession},
		{"D", "d", 0, confirmDelete},
	}
	for _, c := range cases {
		m, _ := wtAt(t, c.ups)
		if m = send(t, m, "ctrl+a", c.upper); m.pending != c.want {
			t.Errorf("C-a %s: pending %v, want %v", c.upper, m.pending, c.want)
		}
		m, _ = wtAt(t, c.ups)
		if m = send(t, m, c.upper); m.pending != promptNone || m.query.Value() != c.upper {
			t.Errorf("bare %s: pending %v query %q", c.upper, m.pending, m.query.Value())
		}
		m, f := wtAt(t, c.ups)
		m = send(t, m, "ctrl+a", "ctrl+"+c.lower)
		switch c.upper {
		case "C":
			if m.label != "new worktree from main: " {
				t.Errorf("C-a ctrl+c: label %q, want the lowercase action", m.label)
			}
		case "R":
			if m.pending != promptRenameWindow {
				t.Errorf("C-a ctrl+r: %v", m.pending)
			}
		case "Q":
			if m.pending != promptNone || len(f.calls) != 1 || !strings.HasPrefix(f.calls[0], "kill-") || strings.HasPrefix(f.calls[0], "kill-session") {
				t.Errorf("C-a ctrl+q: %v %q", m.pending, f.calls)
			}
		case "D":
			if m.pending != promptNone || len(f.calls) != 0 || m.armed {
				t.Errorf("C-a ctrl+d: %v %q (d has no action)", m.pending, f.calls)
			}
		}
	}
}

// ctrl-c closes; C-a c and C-a ctrl-c start the create prompt; C-a C-a
// stays armed; C-a esc closes; an unbound letter after C-a types it.
func TestCtrlCAndCreate(t *testing.T) {
	m, f := wtAt(t, 0)
	if m = send(t, m, "ctrl+c"); !m.quitting || len(f.calls) != 0 {
		t.Errorf("ctrl+c: quitting=%v calls=%v", m.quitting, f.calls)
	}
	for _, k := range []string{"c", "ctrl+c"} {
		m, _ = wtAt(t, 0)
		if m = send(t, m, "ctrl+a", k); m.quitting || m.pending != promptNewWorktree {
			t.Errorf("C-a %s: quitting=%v pending=%v", k, m.quitting, m.pending)
		}
	}
	m, _ = newTest(t)
	if m = send(t, m, "ctrl+a", "ctrl+c"); m.quitting || m.pending != promptNone {
		t.Errorf("C-a ctrl+c on a plain row: quitting=%v pending=%v", m.quitting, m.pending)
	}
	if m = send(t, m, "ctrl+a", "ctrl+a"); !m.armed {
		t.Error("C-a C-a should stay armed")
	}
	if m = send(t, m, "esc"); !m.quitting {
		t.Error("C-a esc should close")
	}
	m, _ = newTest(t)
	if m = send(t, m, "ctrl+a", "z", "n"); m.query.Value() != "zn" || m.armed {
		t.Errorf("C-a z, then bare n: query %q armed %v", m.query.Value(), m.armed)
	}
}

// Prompts are a separate keymap: ctrl-u, ctrl-w, ctrl-a, ctrl-k and ctrl-h
// edit, and no lettered action fires inside one.
func TestPromptKeysNotActions(t *testing.T) {
	m, f := newTest(t)
	m = send(t, m, "ctrl+p", "ctrl+a", "r") // "special-feature-flags"
	sel := m.sel
	m = send(t, m, "ctrl+h", "ctrl+h", "ctrl+h", "ctrl+h", "ctrl+h")
	if m.pending != promptRenameWindow || m.prompt.Value() != "special-feature-" || m.sel != sel {
		t.Fatalf("ctrl+h is backspace: %v %q", m.pending, m.prompt.Value())
	}
	m = send(t, m, " ", "a", "b", "ctrl+w")
	if m.pending != promptRenameWindow || m.prompt.Value() != "special-feature- " {
		t.Fatalf("ctrl+w deletes a word: %v %q", m.pending, m.prompt.Value())
	}
	m = send(t, m, "ctrl+a", "X", "ctrl+k")
	if m.prompt.Value() != "X" {
		t.Errorf("ctrl+a goes to the start, ctrl+k deletes after: %q", m.prompt.Value())
	}
	m = send(t, m, "ctrl+n", "ctrl+p", "ctrl+q", "ctrl+t", "ctrl+x", "ctrl+s", "ctrl+r", "ctrl+l", "ctrl+j")
	if m.pending != promptRenameWindow || len(f.calls) != 0 || m.fullRepo || m.armed || m.sel != sel || sessionName(m) != "roll-web-funnel-changes" {
		t.Errorf("an action fired in a prompt: %v %q", m.pending, f.calls)
	}
	m = send(t, m, "ctrl+u", "Z", "enter")
	if want := []string{"rename-window $4@w1-special-feature-flags Z"}; !reflect.DeepEqual(f.calls, want) {
		t.Errorf("calls %q", f.calls)
	}
}
