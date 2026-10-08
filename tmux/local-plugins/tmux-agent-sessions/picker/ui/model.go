package ui

import (
	"fmt"

	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"agentpicker/state"
)

// Bubble Tea issue #1718: the size can read as 0 under tmux, so render at
// 80x24 until a real size arrives.
const fallbackW, fallbackH = 80, 24

// promptKind is what an inline prompt (C-a c/C/r/R) or confirmation (C-a Q)
// will do on submit.
type promptKind int

const (
	promptNone promptKind = iota
	promptNewWindow
	promptNewSession
	promptRenameWindow
	promptRenameSession
	confirmKillSession
)

var promptLabels = map[promptKind]string{
	promptNewWindow:     "new window: ",
	promptNewSession:    "new session: ",
	promptRenameWindow:  "rename window: ",
	promptRenameSession: "rename session: ",
}

// actionMsg reports a finished stay-open action and the reloaded snapshot.
type actionMsg struct {
	snap *state.Snapshot
	err  error
}

// exitMsg reports a finished Switch or CreateSession.
type exitMsg struct{ err error }

type model struct {
	act  state.Actions
	snap *state.Snapshot
	m    *matcher

	w, h int

	query  textinput.Model
	prompt textinput.Model

	matches []int   // indexes into snap.Sessions, display order
	pos     [][]int // highlight positions per match
	cur     int     // cursor in matches
	top     int     // first visible match when more match than the list shows

	chipIcons bool // ctrl+w: row status chips show icons, not words (D57)
	cards     []card
	sel       int // selected card
	gridTop   int // first visible grid row

	armed     bool
	pending   promptKind
	target    *state.Session // session a prompt or confirmation acts on
	targetWin *state.Window
	err       error
	quitting  bool
}

func newModel(a state.Actions, snap *state.Snapshot, err error) model {
	if snap == nil {
		snap = &state.Snapshot{}
	}
	m := model{
		act:    a,
		snap:   snap,
		m:      newMatcher(),
		w:      fallbackW,
		h:      fallbackH,
		query:  newInput(false),
		prompt: newInput(true),
		err:    err,
	}
	m.query.Focus()
	m.refilter()
	n := len(m.matches)
	if n > 1 {
		m.cur = n - 2 // the previous session (D13)
	}
	m.top = max(0, n-m.listHeight()) // bottom-anchored: the current session shows
	m.listFollow()
	m.resetCards()
	return m
}

// newInput is a textinput whose keymap leaves the picker's control keys
// alone: typing, backspace, delete, left/right, home/end and word moves
// still edit. Prompts (rename, new window, new session) have no picker
// keys to protect, so they also get ctrl-u, ctrl-w, ctrl-a and ctrl-k as in
// tmux's own command prompt, which is how a prefilled name gets cleared.
func newInput(prompt bool) textinput.Model {
	t := textinput.New()
	t.Prompt = ""
	km := textinput.DefaultKeyMap()
	none := key.NewBinding(key.WithDisabled())
	km.DeleteWordBackward = key.NewBinding(key.WithKeys("alt+backspace", "ctrl+backspace"))
	km.DeleteAfterCursor = none
	km.DeleteBeforeCursor = none
	km.DeleteCharacterForward = key.NewBinding(key.WithKeys("delete"))
	km.LineStart = key.NewBinding(key.WithKeys("home"))
	km.Paste = none // terminal paste still arrives as a paste event
	km.AcceptSuggestion = none
	km.NextSuggestion = none
	km.PrevSuggestion = none
	if prompt {
		km.DeleteWordBackward = key.NewBinding(key.WithKeys("alt+backspace", "ctrl+backspace", "ctrl+w"))
		km.DeleteBeforeCursor = key.NewBinding(key.WithKeys("ctrl+u"))
		km.DeleteAfterCursor = key.NewBinding(key.WithKeys("ctrl+k"))
		km.LineStart = key.NewBinding(key.WithKeys("home", "ctrl+a"))
	}
	t.KeyMap = km
	st := textinput.DefaultDarkStyles()
	st.Focused.Text = lipgloss.NewStyle().Foreground(lipgloss.Color(cText))
	st.Focused.Prompt = lipgloss.NewStyle()
	st.Cursor.Color = lipgloss.Color(cRosewater)
	st.Cursor.Blink = false // static block: no blink ticks
	t.SetStyles(st)
	return t
}

func (m model) Init() tea.Cmd { return nil }

// session is the session under the cursor, or nil when nothing matches.
func (m model) session() *state.Session {
	if m.cur < 0 || m.cur >= len(m.matches) {
		return nil
	}
	return m.snap.Sessions[m.matches[m.cur]]
}

func (m model) card() (card, bool) {
	if m.sel < 0 || m.sel >= len(m.cards) {
		return card{}, false
	}
	return m.cards[m.sel], true
}

// refilter recomputes matches for the current query.
func (m *model) refilter() {
	m.matches, m.pos = m.matches[:0], m.pos[:0]
	q := m.query.Value()
	for i, s := range m.snap.Sessions {
		if ok, pos := m.m.match(q, s.Name); ok {
			m.matches = append(m.matches, i)
			m.pos = append(m.pos, pos)
		}
	}
	m.cur = len(m.matches) - 1
}

// listFollow keeps the cursor inside the visible list rows.
func (m *model) listFollow() {
	n, rows := len(m.matches), m.listHeight()
	if n <= rows {
		m.top = 0
		return
	}
	m.top = min(max(m.top, 0), n-rows)
	if m.cur < m.top {
		m.top = m.cur
	}
	if rows > 0 && m.cur >= m.top+rows {
		m.top = m.cur - rows + 1
	}
}

// resetCards rebuilds the grid for the session under the cursor and
// selects the D15 default.
func (m *model) resetCards() {
	s := m.session()
	m.cards = buildCards(s)
	m.sel = defaultCard(s, m.cards)
	m.gridTop = 0
	m.gridFollow()
}

// heights splits the screen, top to bottom: the grid, listH session rows,
// then the input line, with a rule above and below it when rules is 2
// (D44). The input line always shows. A short screen takes rows from the
// grid first (render hides it below one card row), then from the list
// down to one row, and drops the rules only when no list row would be
// left.
func (m model) heights() (gridH, listH, rules int) {
	h := max(0, m.h-1)
	if h >= 3 {
		rules = 2
		h -= rules
	}
	listH = min(listRows, h)
	return h - listH, listH, rules
}

func (m model) gridHeight() int { g, _, _ := m.heights(); return g }
func (m model) listHeight() int { _, l, _ := m.heights(); return l }

// gridFollow scrolls the grid so the selected card's row shows in full
// (not just as the peek under the full rows, D36).
func (m *model) gridFollow() {
	if len(m.cards) == 0 {
		m.gridTop = 0
		return
	}
	g := layoutGrid(m.cards, m.w, m.sel, m.snap.Now)
	row := m.sel / g.cols
	if row < m.gridTop {
		m.gridTop = row
	}
	m.gridTop = min(m.gridTop, len(g.rowH)-1)
	for m.gridTop < row {
		if full, _ := g.visible(m.gridTop, m.gridHeight()); row < m.gridTop+full {
			break
		}
		m.gridTop++
	}
}

func (m *model) moveSession(d int) {
	n := len(m.matches)
	if n == 0 {
		return
	}
	c := min(max(m.cur+d, 0), n-1)
	if c == m.cur {
		return
	}
	m.cur = c
	m.listFollow()
	m.resetCards()
}

func (m *model) moveCard(d int) {
	if len(m.cards) == 0 {
		return
	}
	m.sel = min(max(m.sel+d, 0), len(m.cards)-1)
	m.gridFollow()
}

// moveCardRow moves one grid row, keeping the column; on a short last row
// it lands on the last card (D30).
func (m *model) moveCardRow(d int) {
	if len(m.cards) == 0 {
		return
	}
	cols := gridCols(m.w)
	i := m.sel + d*cols
	if i < 0 {
		return
	}
	if i >= len(m.cards) {
		if m.sel/cols == (len(m.cards)-1)/cols {
			return // already on the last row
		}
		i = len(m.cards) - 1
	}
	m.sel = i
	m.gridFollow()
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		if msg.Width > 0 && msg.Height > 0 {
			m.w, m.h = msg.Width, msg.Height
			m.listFollow()
			m.gridFollow()
		}
		return m, nil
	case actionMsg:
		m.applyReload(msg)
		return m, nil
	case exitMsg:
		if msg.err != nil {
			m.err = msg.err
			return m, nil
		}
		m.quitting = true
		return m, tea.Quit
	case tea.PasteMsg:
		if m.pending != promptNone && m.pending != confirmKillSession {
			var cmd tea.Cmd
			m.prompt, cmd = m.prompt.Update(msg)
			return m, cmd
		}
		return m.editQuery(msg)
	case tea.KeyPressMsg:
		m.err = nil
		if m.pending != promptNone {
			return m.promptKey(msg)
		}
		if m.armed {
			m.armed = false
			if cmd, ok := m.prefixKey(msg.String()); ok {
				return m, cmd
			}
		}
		return m.key(msg)
	}
	return m, nil
}

func (m model) key(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "esc", "ctrl+c":
		m.quitting = true
		return m, tea.Quit
	case "ctrl+a":
		m.armed = true
	case "ctrl+n", "down":
		m.moveSession(1)
	case "ctrl+p", "up":
		m.moveSession(-1)
	case "ctrl+j":
		m.moveCard(1)
	case "ctrl+k":
		m.moveCard(-1)
	case "ctrl+d":
		m.moveCardRow(1)
	case "ctrl+u":
		m.moveCardRow(-1)
	case "ctrl+w":
		m.chipIcons = !m.chipIcons
	case "enter":
		return m, m.enter()
	default:
		return m.editQuery(msg)
	}
	return m, nil
}

// editQuery passes a key or paste to the query, refiltering on change.
// After a change the cursor goes to the bottom match.
func (m model) editQuery(msg tea.Msg) (tea.Model, tea.Cmd) {
	before := m.query.Value()
	var cmd tea.Cmd
	m.query, cmd = m.query.Update(msg)
	if m.query.Value() != before {
		m.refilter()
		m.top = 0
		m.listFollow()
		m.resetCards()
	}
	return m, cmd
}

func (m model) enter() tea.Cmd {
	s := m.session()
	if s == nil {
		name := m.query.Value()
		if name == "" {
			return nil
		}
		return func() tea.Msg { return exitMsg{m.act.CreateSession(name)} }
	}
	var w *state.Window
	var p *state.Pane
	if c, ok := m.card(); ok {
		w = c.win
		if c.split { // a window card keeps the window's active pane (Q27)
			p = c.pane
		}
	}
	return func() tea.Msg { return exitMsg{m.act.Switch(s, w, p)} }
}

// prefixKey handles the key after C-a (D16). ok is false for keys that are
// not prefix actions; those do their normal job.
func (m *model) prefixKey(k string) (tea.Cmd, bool) {
	s := m.session()
	c, hasCard := m.card()
	switch k {
	case "C":
		m.startPrompt(promptNewSession, m.query.Value())
		return nil, true
	case "c":
		if s != nil {
			m.target = s
			m.startPrompt(promptNewWindow, "")
		}
		return nil, true
	case "r":
		if hasCard {
			m.target, m.targetWin = s, c.win
			m.startPrompt(promptRenameWindow, c.win.Name)
		}
		return nil, true
	case "R":
		if s != nil {
			m.target = s
			m.startPrompt(promptRenameSession, s.Name)
		}
		return nil, true
	case "q":
		if !hasCard {
			return nil, true
		}
		if c.split {
			return m.run(func() error { return m.act.KillPane(c.pane) }), true
		}
		return m.run(func() error { return m.act.KillWindow(c.win) }), true
	case "Q":
		if s != nil {
			m.target = s
			m.pending = confirmKillSession
		}
		return nil, true
	}
	return nil, false
}

func (m *model) startPrompt(k promptKind, value string) {
	m.pending = k
	m.prompt.SetValue(value)
	m.prompt.CursorEnd()
	m.prompt.Focus()
}

func (m *model) endPrompt() {
	m.pending = promptNone
	m.prompt.Blur()
	m.prompt.SetValue("")
}

func (m model) promptKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	kind, s, w := m.pending, m.target, m.targetWin
	if kind == confirmKillSession {
		m.endPrompt()
		if msg.String() == "y" || msg.String() == "Y" {
			return m, m.run(func() error { return m.act.KillSession(s) })
		}
		return m, nil
	}
	switch msg.String() {
	case "esc", "ctrl+c":
		m.endPrompt()
		return m, nil
	case "enter":
		name := m.prompt.Value()
		m.endPrompt()
		switch kind {
		case promptNewWindow:
			// An empty name keeps tmux's automatic naming.
			return m, m.run(func() error { return m.act.NewWindow(s, name) })
		case promptNewSession:
			if name == "" {
				return m, nil
			}
			return m, m.run(func() error { return m.act.NewSession(name) })
		case promptRenameWindow:
			if name == "" {
				return m, nil
			}
			return m, m.run(func() error { return m.act.RenameWindow(w, name) })
		case promptRenameSession:
			if name == "" {
				return m, nil
			}
			return m, m.run(func() error { return m.act.RenameSession(s, name) })
		}
		return m, nil
	}
	var cmd tea.Cmd
	m.prompt, cmd = m.prompt.Update(msg)
	return m, cmd
}

// run performs a stay-open action, then reloads even when the action
// failed: a kill can report an error after it killed. The action's error
// wins over a reload error; a failed reload keeps the old snapshot.
func (m model) run(f func() error) tea.Cmd {
	a := m.act
	return func() tea.Msg {
		actErr := f()
		snap, err := a.Load()
		if err != nil {
			snap = nil
		}
		if actErr != nil {
			err = actErr
		}
		return actionMsg{snap: snap, err: err}
	}
}

// applyReload swaps in a fresh snapshot, keeping the selected session and
// card by id when they still exist.
func (m *model) applyReload(msg actionMsg) {
	m.err = msg.err
	if msg.snap == nil {
		return
	}
	var sid, cid string
	if s := m.session(); s != nil {
		sid = s.ID
	}
	if c, ok := m.card(); ok {
		cid = c.id()
	}
	oldCur, oldSel := m.cur, m.sel

	m.snap = msg.snap
	m.refilter()
	m.cur = min(max(oldCur, 0), len(m.matches)-1)
	sameSession := false
	for i, idx := range m.matches {
		if m.snap.Sessions[idx].ID == sid {
			m.cur, sameSession = i, true
			break
		}
	}
	m.listFollow()
	m.resetCards()
	if !sameSession {
		return
	}
	found := false
	for i, c := range m.cards {
		if c.id() == cid {
			m.sel, found = i, true
			break
		}
	}
	if !found && len(m.cards) > 0 {
		m.sel = min(oldSel, len(m.cards)-1)
	}
	m.gridFollow()
}

func (m model) View() tea.View {
	v := tea.NewView(m.render())
	v.AltScreen = true
	return v
}

func (m model) countText() string {
	return fmt.Sprintf("%d/%d", len(m.matches), len(m.snap.Sessions))
}
