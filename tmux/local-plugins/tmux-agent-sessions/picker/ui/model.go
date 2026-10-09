package ui

import (
	"cmp"
	"fmt"
	"path/filepath"
	"slices"

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

// listMode is what the list rows are: sessions, or git worktrees grouping
// panes by their directory. ctrl+w switches.
type listMode int

const (
	modeSessions listMode = iota
	modeWorktrees
)

// openMode is the mode the picker opens in (D71). With no pane in any
// repo there are no worktree rows, so it opens on sessions instead.
var openMode = modeWorktrees

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

	mode      listMode
	rows      []state.Row          // the mode's rows: snap.Sessions or snap.Worktrees
	repo      string               // worktree repo filter, "" for All; kept across modes
	fullRepo  bool                 // worktree rows show full repo names, kept across modes
	badges    map[string]repoBadge // per repo name, from the snapshot's worktrees
	repoW     int                  // full-repo badge width
	repoOrder []string             // repos in the order tab steps through them, fixed at open (D83)

	matches []int   // indexes into rows, display order
	total   int     // rows that pass the repo filter
	pos     [][]int // highlight positions per match
	repoHit []bool  // per match: the query matched the worktree's repo name (D82)
	cur     int     // cursor in matches
	top     int     // first visible match when more match than the list shows

	cards   []card
	sel     int // selected card
	gridTop int // first visible grid row

	armed     bool
	pending   promptKind
	target    *state.Session // session a prompt or confirmation acts on
	targetWin *state.Window
	targetDir string // start directory of a new window or session, "" for the default
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
	if openMode == modeWorktrees && len(snap.Worktrees) > 0 {
		m.mode = modeWorktrees
	}
	m.indexRepos()
	m.repoOrder = openRepoOrder(snap)
	m.setRows()
	m.resetList()
	return m
}

// repoFullMaxW caps the full-repo badge width.
const repoFullMaxW = 24

// indexRepos assigns every repo of the snapshot its badge (D76) and sets
// the full-repo badge width: the widest repo name, capped at repoFullMaxW.
func (m *model) indexRepos() {
	var names []string
	m.repoW = 0
	for _, t := range m.snap.Worktrees {
		names = append(names, t.Repo)
		m.repoW = max(m.repoW, width(oneLine(t.Repo)))
	}
	m.repoW = min(m.repoW, repoFullMaxW)
	m.badges = assignRepoBadges(names)
}

// setRows points rows at the current mode's rows.
func (m *model) setRows() {
	if m.mode == modeWorktrees {
		m.rows = make([]state.Row, 0, len(m.snap.Worktrees))
		for _, t := range m.snap.Worktrees {
			m.rows = append(m.rows, t)
		}
		return
	}
	m.rows = make([]state.Row, 0, len(m.snap.Sessions))
	for _, s := range m.snap.Sessions {
		m.rows = append(m.rows, s)
	}
}

// resetList refilters and puts the list and grid at their defaults, as on
// open: the cursor on the previous row (D13), the list bottom-anchored so
// the current row shows.
func (m *model) resetList() {
	m.refilter()
	n := len(m.matches)
	// With a query the cursor stays on the bottom match, as after typing.
	// A worktree list without a current row at the bottom starts there too.
	if n > 1 && m.query.Value() == "" && (m.mode == modeSessions || m.rows[m.matches[n-1]].IsCurrent()) {
		m.cur = n - 2
	}
	m.top = max(0, n-m.listHeight())
	m.listFollow()
	m.resetCards()
}

// newInput is a textinput whose keymap leaves the picker's control keys
// alone: typing, backspace, delete, left/right, home/end and word moves
// still edit. The query drops ctrl-h from backspace, since the grid uses
// it. Prompts (rename, new window, new session) have no picker
// keys to protect, so they also get ctrl-u, ctrl-w, ctrl-a and ctrl-k as in
// tmux's own command prompt, which is how a prefilled name gets cleared.
func newInput(prompt bool) textinput.Model {
	t := textinput.New()
	t.Prompt = ""
	km := textinput.DefaultKeyMap()
	none := key.NewBinding(key.WithDisabled())
	km.DeleteWordBackward = key.NewBinding(key.WithKeys("alt+backspace", "ctrl+backspace"))
	km.DeleteCharacterBackward = key.NewBinding(key.WithKeys("backspace"))
	km.DeleteAfterCursor = none
	km.DeleteBeforeCursor = none
	km.DeleteCharacterForward = key.NewBinding(key.WithKeys("delete"))
	km.LineStart = key.NewBinding(key.WithKeys("home"))
	km.Paste = none // terminal paste still arrives as a paste event
	km.AcceptSuggestion = none
	km.NextSuggestion = none
	km.PrevSuggestion = none
	if prompt {
		km.DeleteCharacterBackward = key.NewBinding(key.WithKeys("backspace", "ctrl+h"))
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

// row is the row under the cursor, or nil when nothing matches.
func (m model) row() state.Row {
	if m.cur < 0 || m.cur >= len(m.matches) {
		return nil
	}
	return m.rows[m.matches[m.cur]]
}

// session is the session under the cursor, nil when nothing matches or in
// worktree mode.
func (m model) session() *state.Session {
	s, _ := m.row().(*state.Session)
	return s
}

// worktree is the worktree under the cursor, nil when nothing matches or
// in session mode.
func (m model) worktree() *state.Worktree {
	t, _ := m.row().(*state.Worktree)
	return t
}

func (m model) card() (card, bool) {
	if m.sel < 0 || m.sel >= len(m.cards) {
		return card{}, false
	}
	return m.cards[m.sel], true
}

// refilter recomputes matches for the repo filter, then the query. Matches
// keep the rows' order: a match never re-ranks. A worktree row also matches
// when the query matches its repo name (D82); repoHit records that, and pos
// stays nil when only the repo matched.
func (m *model) refilter() {
	m.matches, m.pos, m.repoHit = m.matches[:0], m.pos[:0], m.repoHit[:0]
	m.total = 0
	q := m.query.Value()
	for i, r := range m.rows {
		if !m.inFilter(r) {
			continue
		}
		m.total++
		ok, pos := m.m.match(q, rowLabel(r))
		hit := false
		if t, isWT := r.(*state.Worktree); isWT && q != "" {
			hit, _ = m.m.match(q, t.Repo)
		}
		if ok || hit {
			m.matches = append(m.matches, i)
			m.pos = append(m.pos, pos)
			m.repoHit = append(m.repoHit, hit)
		}
	}
	m.cur = len(m.matches) - 1
}

// rowLabel is the text the query matches: a session's name, a worktree's
// branch or, when detached, its commit id, whatever the row labels show.
func rowLabel(r state.Row) string {
	switch r := r.(type) {
	case *state.Session:
		return r.Name
	case *state.Worktree:
		if r.Detached() {
			return r.Head
		}
		return r.Branch
	}
	return ""
}

// inFilter applies the repo filter, which only worktree rows have.
func (m model) inFilter(r state.Row) bool {
	t, ok := r.(*state.Worktree)
	return !ok || m.repo == "" || t.Repo == m.repo
}

// repoRecency lists the snapshot's repos by last access, newest first. A
// repo's access is the newest Recency of its worktrees; ties keep first
// appearance scanning the worktree rows from the bottom up.
func repoRecency(snap *state.Snapshot) []string {
	var out []string
	at := map[string]int64{}
	for i := len(snap.Worktrees) - 1; i >= 0; i-- {
		t := snap.Worktrees[i]
		if _, seen := at[t.Repo]; !seen {
			out = append(out, t.Repo)
		}
		at[t.Repo] = max(at[t.Repo], t.Recency())
	}
	slices.SortStableFunc(out, func(a, b string) int { return cmp.Compare(at[b], at[a]) })
	return out
}

// openRepoOrder is the tab order at open (D83): the current worktree's
// repo first, then the others by last access.
func openRepoOrder(snap *state.Snapshot) []string {
	out := repoRecency(snap)
	for _, t := range snap.Worktrees {
		if t.IsCurrent() {
			i := slices.Index(out, t.Repo)
			copy(out[1:i+1], out[:i])
			out[0] = t.Repo
			break
		}
	}
	return out
}

// reloadRepoOrder carries the frozen tab order over to a reloaded snapshot:
// repos still present keep their place, vanished ones drop, and new ones
// follow in recency order.
func reloadRepoOrder(old []string, snap *state.Snapshot) []string {
	fresh := repoRecency(snap)
	var out []string
	for _, r := range old {
		if slices.Contains(fresh, r) {
			out = append(out, r)
		}
	}
	for _, r := range fresh {
		if !slices.Contains(out, r) {
			out = append(out, r)
		}
	}
	return out
}

// cycleRepo steps the repo filter d places through All and the repos,
// wrapping both ways, and resets the list as on open.
func (m *model) cycleRepo(d int) {
	opts := append([]string{""}, m.repoOrder...)
	i := max(slices.Index(opts, m.repo), 0)
	m.repo = opts[((i+d)%len(opts)+len(opts))%len(opts)]
	m.resetList()
}

// toggleMode switches between session and worktree rows. The query and
// the repo filter stay; the cursor and the card go to their defaults.
func (m *model) toggleMode() {
	if m.mode == modeSessions {
		m.mode = modeWorktrees
	} else {
		m.mode = modeSessions
	}
	m.setRows()
	m.resetList()
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

// resetCards rebuilds the grid for the row under the cursor and selects
// the default card.
func (m *model) resetCards() {
	m.cards, m.sel = nil, 0
	if r := m.row(); r != nil {
		m.cards = rowCards(r)
		m.sel = defaultCard(m.cards, defaultPane(r))
	}
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

// moveCardCol moves one card left or right within its grid row, stopping
// at the row's edges.
func (m *model) moveCardCol(d int) {
	if len(m.cards) == 0 {
		return
	}
	cols := gridCols(m.w)
	c, i := m.sel%cols+d, m.sel+d
	if c < 0 || c >= cols || i >= len(m.cards) {
		return
	}
	m.sel = i
	m.gridFollow()
}

// moveCardRow moves one grid row, keeping the column; on a short last row
// it lands on the last card (D30). It stops at the top and bottom rows.
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
	case "ctrl+h":
		m.moveCardCol(-1)
	case "ctrl+l":
		m.moveCardCol(1)
	case "ctrl+j":
		m.moveCardRow(1)
	case "ctrl+k":
		m.moveCardRow(-1)
	case "ctrl+w":
		m.toggleMode()
	case "ctrl+t":
		if m.mode == modeWorktrees {
			m.fullRepo = !m.fullRepo
		}
	case "tab":
		if m.mode == modeWorktrees {
			m.cycleRepo(1)
		}
	case "shift+tab":
		if m.mode == modeWorktrees {
			m.cycleRepo(-1)
		}
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
	if s == nil && m.mode == modeWorktrees {
		// A worktree row is no session: switch by its card, and an
		// unmatched query creates nothing.
		if c, ok := m.card(); ok {
			s = c.win.Session
		} else {
			return nil
		}
	}
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
// not prefix actions; those do their normal job. In worktree mode new
// windows and sessions start in the worktree's root, and the session
// actions (R, Q) do nothing: a worktree row is no session.
func (m *model) prefixKey(k string) (tea.Cmd, bool) {
	s, t := m.session(), m.worktree()
	c, hasCard := m.card()
	switch k {
	case "C":
		switch {
		case m.mode == modeSessions:
			m.targetDir = ""
			m.startPrompt(promptNewSession, m.query.Value())
		case t != nil:
			m.targetDir = t.Root
			m.startPrompt(promptNewSession, filepath.Base(t.Root))
		}
		return nil, true
	case "c":
		switch {
		case s != nil:
			m.target, m.targetDir = s, ""
			m.startPrompt(promptNewWindow, "")
		case t != nil && hasCard:
			m.target, m.targetDir = c.win.Session, t.Root
			m.startPrompt(promptNewWindow, "")
		}
		return nil, true
	case "r":
		if hasCard {
			m.target, m.targetWin = c.win.Session, c.win
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
	kind, s, w, dir := m.pending, m.target, m.targetWin, m.targetDir
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
			return m, m.run(func() error { return m.act.NewWindow(s, dir, name) })
		case promptNewSession:
			if name == "" {
				return m, nil
			}
			return m, m.run(func() error { return m.act.NewSession(name, dir) })
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

// applyReload swaps in a fresh snapshot, keeping the selected row (a
// session id or a worktree root) and card by id when they still exist. A
// repo filter whose repo is gone goes back to All.
func (m *model) applyReload(msg actionMsg) {
	m.err = msg.err
	if msg.snap == nil {
		return
	}
	var rid, cid string
	if r := m.row(); r != nil {
		rid = r.RowID()
	}
	if c, ok := m.card(); ok {
		cid = c.id()
	}
	oldCur, oldSel := m.cur, m.sel

	m.snap = msg.snap
	m.indexRepos()
	m.repoOrder = reloadRepoOrder(m.repoOrder, msg.snap)
	m.setRows()
	if m.repo != "" && !slices.Contains(m.repoOrder, m.repo) {
		m.repo = ""
	}
	m.refilter()
	m.cur = min(max(oldCur, 0), len(m.matches)-1)
	sameRow := false
	for i, idx := range m.matches {
		if m.rows[idx].RowID() == rid {
			m.cur, sameRow = i, true
			break
		}
	}
	m.listFollow()
	m.resetCards()
	if !sameRow {
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

// countText is matches over the rows that pass the repo filter.
func (m model) countText() string {
	return fmt.Sprintf("%d/%d", len(m.matches), m.total)
}

// filterChip is the repo filter's indicator, shown in worktree mode only:
// All in the panes chip colours, or the repo on its badge shade (D80).
func (m model) filterChip() filterChip {
	if m.mode != modeWorktrees {
		return filterChip{}
	}
	if b, ok := m.badges[m.repo]; ok && m.repo != "" {
		return filterChip{text: m.repo, fg: b.fg, bg: b.bg}
	}
	return filterChip{text: "All", fg: cText, bg: panesChipBg}
}
