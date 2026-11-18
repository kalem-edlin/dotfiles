package ui

import (
	"cmp"
	"fmt"
	"slices"
	"strings"
	"time"

	"charm.land/bubbles/v2/key"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"

	"agentpicker/inspect"
	"agentpicker/state"
)

// Bubble Tea issue #1718: the size can read as 0 under tmux, so render at
// 80x24 until a real size arrives.
const fallbackW, fallbackH = 80, 24

// promptKind is what an inline prompt (w/s/r/R/c/C/x) or confirmation
// (Q, D) will do on submit. There is one confirm per action (D105).
type promptKind int

const (
	promptNone promptKind = iota
	promptNewWindow
	promptNewSession
	promptRenameWindow
	promptRenameSession
	confirmKillSession
	promptNewWorktree // C-a c, C-a C: branch name for wt new
	promptRepurpose   // C-a x: branch name for wt repurpose
	confirmDelete     // C-a D: delete to the Trash?
	confirmEnvRefresh // C-a e, C-a E: refresh env files across the repo's worktrees?
)

// isConfirm reports a y/N confirmation, which takes one key and no text.
func isConfirm(k promptKind) bool {
	switch k {
	case confirmKillSession, confirmDelete, confirmEnvRefresh:
		return true
	}
	return false
}

var promptLabels = map[promptKind]string{
	promptNewWindow:     "new window: ",
	promptNewSession:    "new session: ",
	promptRenameWindow:  "rename window: ",
	promptRenameSession: "rename session: ",
}

// restDelay is how long the cursor must rest on a worktree row before its
// git state is read (V7), so scrolling past rows spawns nothing.
var restDelay = 120 * time.Millisecond

// Probes for the async parts of a worktree row; tests replace them.
var (
	probeHeavy = inspect.HeavySymbols
	readGit    = inspect.ReadGit
)

// actionMsg reports a finished stay-open action and the reloaded snapshot.
// status is the action's result line; forget is a worktree root whose
// cached git state is stale (repurpose, delete).
type actionMsg struct {
	snap   *state.Snapshot
	err    error
	status string
	forget string
}

// exitMsg reports a finished Switch or CreateSession.
type exitMsg struct{ err error }

// wtStatusMsg is `wt status` for the delete refusals of a main or locked
// row (C-a D): linked worktrees, the lock reason.
type wtStatusMsg struct {
	st  state.WTStatus
	err error
}

// heavyMsg carries heavy symbols per worktree root (V8), probed after the
// first frame.
type heavyMsg map[string][]string

// restMsg fires restDelay after the cursor reached a worktree row; seq
// tells whether it has moved since.
type restMsg struct {
	seq  int
	root string
}

// gitMsg is a worktree's git state for the preview (V7).
type gitMsg struct {
	root string
	git  inspect.Git
}

type model struct {
	act  state.Actions
	snap *state.Snapshot
	m    *matcher

	w, h int

	query  textinput.Model
	prompt textinput.Model

	rows      []state.Row          // every worktree and every session no worktree has, display order
	repo      string               // worktree repo filter, "" for All
	fullRepo  bool                 // worktree rows show full repo names
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

	// Worktree lifecycle (C-a c/C/x/D, B3, D103).
	targetWT   *state.Worktree // worktree a lifecycle prompt or confirm acts on
	targetHere bool            // C-a E: the row's worktree is the env source (D109)
	targetFrom string          // C-a C: the base ref, "" for wt's default (main)
	label      string          // a lifecycle prompt's or confirm's text
	busy       string          // "running wt ..." while a wt call runs; keys wait
	// targetRemote: the delete target's root was remote when C-a D was
	// pressed (Actions.RootRemote), so the confirm says so and wt rm gets
	// --discard-remote.
	targetRemote bool
	status       string // the last lifecycle result, until the next key

	// async enables the off-frame work: the heavy probe from Init and the
	// git read when the cursor rests (Run sets it; model tests drive the
	// messages by hand).
	async   bool
	heavy   map[string][]string    // heavy symbols per worktree root, once probed
	git     map[string]inspect.Git // preview git state per root, read this run
	restSeq int                    // bumped on every row change, for restMsg
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
		heavy:  map[string][]string{},
		git:    map[string]inspect.Git{},
	}
	m.query.Focus()
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

// setRows builds the one list (V5): every worktree, with or without a
// session, and every session named after no worktree (V3).
func (m *model) setRows() {
	m.rows = state.ListRows(m.snap.Worktrees, m.snap.Sessions)
}

// hasRepos reports whether any worktree was discovered; without one the
// repo filter, its chip and full-repo mode do nothing.
func (m model) hasRepos() bool { return len(m.snap.Worktrees) > 0 }

// resetList refilters and puts the list and grid at their defaults, as on
// open: the cursor on the previous row (D13), the list bottom-anchored so
// the current row shows.
func (m *model) resetList() {
	m.refilter()
	n := len(m.matches)
	// With a query the cursor stays on the bottom match, as after typing.
	// A list without the current row at the bottom starts there too.
	if n > 1 && m.query.Value() == "" && m.rows[m.matches[n-1]].IsCurrent() {
		m.cur = n - 2
	}
	m.top = max(0, n-m.listHeight())
	m.listFollow()
	m.resetCards()
}

// newInput is a textinput whose keymap leaves the picker's control keys
// alone: typing, backspace, delete, left/right, home/end and word moves
// still edit. The query drops ctrl-h from backspace, since the grid uses
// it. Prompts (rename, new window, new session, branch names) are a
// separate keymap where no lettered action fires (D104), so they also get
// ctrl-h as backspace and ctrl-u, ctrl-w, ctrl-a and ctrl-k as in tmux's
// own command prompt, which is how a prefilled name gets cleared.
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

// Init starts the heavy probe once the first frame is out (V8).
func (m model) Init() tea.Cmd {
	return tea.Batch(m.heavyCmd(), m.restCmd())
}

// heavyCmd probes every present worktree not probed yet, stat only.
func (m model) heavyCmd() tea.Cmd {
	if !m.async {
		return nil
	}
	var roots []string
	for _, t := range m.snap.Worktrees {
		if _, done := m.heavy[t.Root]; !done && !t.Missing {
			roots = append(roots, t.Root)
		}
	}
	if len(roots) == 0 {
		return nil
	}
	return func() tea.Msg {
		out := make(heavyMsg, len(roots))
		for _, r := range roots {
			out[r] = probeHeavy(r)
		}
		return out
	}
}

// restCmd arms the git read for the worktree row under the cursor (V7):
// it fires after restDelay and only counts if the cursor is still there.
func (m model) restCmd() tea.Cmd {
	t := m.worktree()
	if !m.async || t == nil || t.Missing {
		return nil
	}
	if _, done := m.git[t.Root]; done {
		return nil
	}
	seq, root := m.restSeq, t.Root
	return tea.Tick(restDelay, func(time.Time) tea.Msg { return restMsg{seq, root} })
}

// gitCmd reads root's git state off the UI goroutine.
func gitCmd(root string) tea.Cmd {
	return func() tea.Msg { return gitMsg{root, readGit(root)} }
}

// row is the row under the cursor, or nil when nothing matches.
func (m model) row() state.Row {
	if m.cur < 0 || m.cur >= len(m.matches) {
		return nil
	}
	return m.rows[m.matches[m.cur]]
}

// session is the session under the cursor: a plain session row's, or the
// session of a worktree row (V1: one session per worktree). nil when
// nothing matches or the worktree has no session.
func (m model) session() *state.Session {
	switch r := m.row().(type) {
	case *state.Session:
		return r
	case *state.Worktree:
		return r.Session
	}
	return nil
}

// worktree is the worktree under the cursor, nil when nothing matches or
// the row is a plain session.
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
// stays nil when only the repo matched. It matches on its directory name
// too, which is its session's name, so a session stays findable by the
// name it always had; that match highlights nothing, since the row does
// not show the directory.
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
		hit, dir := false, false
		if t, isWT := r.(*state.Worktree); isWT && q != "" {
			hit, _ = m.m.match(q, t.Repo)
			if !ok && !hit {
				dir, _ = m.m.match(q, t.Name)
			}
		}
		if ok || hit || dir {
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

// inFilter applies the repo filter: a repo shows only its worktrees, so
// plain session rows show under All only.
func (m model) inFilter(r state.Row) bool {
	if m.repo == "" {
		return true
	}
	t, ok := r.(*state.Worktree)
	return ok && t.Repo == m.repo
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

// previewH is the preview's height above the cards: the line and the
// rule under it for a worktree row (V7, D107), none for a plain session
// row.
func (m model) previewH() int {
	if m.worktree() != nil {
		return 2
	}
	return 0
}

// cardsHeight is the grid's room for cards, under the preview line.
func (m model) cardsHeight() int { return max(0, m.gridHeight()-m.previewH()) }

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
		if full, _ := g.visible(m.gridTop, m.cardsHeight()); row < m.gridTop+full {
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

// Update handles msg, then arms the git read when the row under the cursor
// changed (V7).
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	before := ""
	if r := m.row(); r != nil {
		before = r.RowID()
	}
	nm, cmd := m.update(msg)
	m = nm.(model)
	after := ""
	if r := m.row(); r != nil {
		after = r.RowID()
	}
	if after == before {
		return m, cmd
	}
	m.restSeq++
	return m, batch(cmd, m.restCmd())
}

// batch is tea.Batch that hands back a single command unwrapped.
func batch(a, b tea.Cmd) tea.Cmd {
	switch {
	case a == nil:
		return b
	case b == nil:
		return a
	}
	return tea.Batch(a, b)
}

func (m model) update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case heavyMsg:
		for root, syms := range msg {
			m.heavy[root] = syms
		}
		return m, nil
	case restMsg:
		if t := m.worktree(); msg.seq == m.restSeq && t != nil && t.Root == msg.root {
			return m, gitCmd(msg.root)
		}
		return m, nil
	case gitMsg:
		m.git[msg.root] = msg.git
		return m, nil
	case tea.WindowSizeMsg:
		if msg.Width > 0 && msg.Height > 0 {
			m.w, m.h = msg.Width, msg.Height
			m.listFollow()
			m.gridFollow()
		}
		return m, nil
	case actionMsg:
		m.busy, m.status = "", msg.status
		m.applyReload(msg)
		if msg.forget != "" {
			delete(m.git, msg.forget)
			return m, batch(m.heavyCmd(), m.restCmd())
		}
		return m, m.heavyCmd()
	case exitMsg:
		m.busy = ""
		if msg.err != nil {
			m.err = msg.err
			return m, nil
		}
		m.quitting = true
		return m, tea.Quit
	case wtStatusMsg:
		m.busy = ""
		m.deleteConfirm(msg)
		return m, nil
	case tea.PasteMsg:
		if m.busy != "" {
			return m, nil
		}
		if m.pending != promptNone && !isConfirm(m.pending) {
			var cmd tea.Cmd
			m.prompt, cmd = m.prompt.Update(msg)
			return m, cmd
		}
		return m.editQuery(msg)
	case tea.KeyPressMsg:
		if m.busy != "" {
			return m, nil // a wt call is running (at most wtTimeout)
		}
		m.err, m.status = nil, ""
		if m.pending != promptNone {
			return m.promptKey(msg) // prompts have their own keymap (D104)
		}
		return m.key(msg)
	}
	return m, nil
}

// key handles a key outside prompts. Every lettered action has one entry
// in letterAction and three inputs (D104): ctrl-<letter>, C-a <letter>
// and C-a ctrl-<letter>. Uppercase actions are C-a <Letter> only, since
// ctrl carries no shift. ctrl-a is the prefix (C-a C-a stays armed),
// ctrl-c and esc close (so c is C-a c or C-a ctrl-c), and bare letters
// type into the query. After C-a any other key disarms and does its
// normal job (C-a z types z), except N, a dead key since D103.
func (m model) key(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	k, armed := msg.String(), m.armed
	m.armed = false
	switch {
	case k == "ctrl+a":
		m.armed = true
		return m, nil
	case k == "esc", k == "ctrl+c" && !armed:
		m.quitting = true
		return m, tea.Quit
	}
	if l, ok := letterKey(k, armed); ok {
		if cmd, bound := m.letterAction(l); bound {
			return m, cmd
		}
		if armed && l == 'N' {
			return m, nil
		}
	}
	switch k {
	case "down":
		m.moveSession(1)
	case "up":
		m.moveSession(-1)
	case "tab":
		if m.hasRepos() {
			m.cycleRepo(1)
		}
	case "shift+tab":
		if m.hasRepos() {
			m.cycleRepo(-1)
		}
	case "enter":
		cmd := m.enter() // before m is copied out: enter may set busy
		return m, cmd
	default:
		return m.editQuery(msg)
	}
	return m, nil
}

// letterKey normalizes a key for the action table: ctrl-<letter> always,
// and after C-a also <letter> and <Letter>. ctrl-<letter> means the
// lowercase action, armed or not. ok is false for any other key.
func letterKey(k string, armed bool) (rune, bool) {
	if c, ctrl := strings.CutPrefix(k, "ctrl+"); ctrl {
		if len(c) == 1 && c[0] >= 'a' && c[0] <= 'z' {
			return rune(c[0]), true
		}
		return 0, false
	}
	if armed && len(k) == 1 && (k[0] >= 'a' && k[0] <= 'z' || k[0] >= 'A' && k[0] <= 'Z') {
		return rune(k[0]), true
	}
	return 0, false
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

// enter goes to the selected card, in the card's own session. A row
// without cards goes to its session; a worktree row without a session
// creates one named after the directory, rooted there, and goes to it
// (V1); a missing directory refuses. With nothing matched, the query names
// a new session in the home directory.
//
// The worktree lifecycle keys (C-a c/C/x/D) are in letterAction; the tmuxio
// actions rescan the worktrees after each wt call that changes them.
func (m *model) enter() tea.Cmd {
	if c, ok := m.card(); ok {
		var p *state.Pane
		if c.split { // a window card keeps the window's active pane (Q27)
			p = c.pane
		}
		s := c.win.Session
		return func() tea.Msg { return exitMsg{m.act.Switch(s, c.win, p)} }
	}
	if s := m.session(); s != nil {
		return func() tea.Msg { return exitMsg{m.act.Switch(s, nil, nil)} }
	}
	if t := m.worktree(); t != nil {
		if t.Missing {
			root := t.Root
			return func() tea.Msg { return exitMsg{fmt.Errorf("worktree directory is missing: %s", root)} }
		}
		name, root := state.SessionName(t.Name), t.Root
		// A remote root opens through rw open (ssh): keys wait meanwhile.
		m.busy = opening(m.act, root, name)
		a := m.act
		return func() tea.Msg { return exitMsg{a.CreateSession(name, root)} }
	}
	name := m.query.Value()
	if name == "" {
		return nil
	}
	return func() tea.Msg { return exitMsg{m.act.CreateSession(name, "")} }
}

// letterAction runs the action of letter l (D104), the one table behind
// ctrl-<letter>, C-a <letter> and C-a ctrl-<letter>; bound is false for a
// letter with no action. n and p move rows, h, j, k and l move cards and t
// toggles full-repo mode. On a worktree row new windows (w) and sessions
// (s) start in the worktree's root, and the session actions (R, Q) act on
// its session, doing nothing when it has none. The worktree lifecycle
// letters (c, C, x, D) act on a worktree row only (D103).
func (m *model) letterAction(l rune) (cmd tea.Cmd, bound bool) {
	s, t := m.session(), m.worktree()
	c, hasCard := m.card()
	switch l {
	case 'n':
		m.moveSession(1)
	case 'p':
		m.moveSession(-1)
	case 'h':
		m.moveCardCol(-1)
	case 'l':
		m.moveCardCol(1)
	case 'j':
		m.moveCardRow(1)
	case 'k':
		m.moveCardRow(-1)
	case 't':
		if m.hasRepos() {
			m.fullRepo = !m.fullRepo
		}
	case 's':
		switch {
		case t != nil && !t.Missing:
			m.targetDir = t.Root
			m.startPrompt(promptNewSession, state.SessionName(t.Name))
		case t == nil:
			m.targetDir = ""
			m.startPrompt(promptNewSession, m.query.Value())
		}
	case 'w':
		switch {
		case s != nil && t != nil:
			m.target, m.targetDir = s, t.Root
			m.startPrompt(promptNewWindow, "")
		case s != nil:
			m.target, m.targetDir = s, ""
			m.startPrompt(promptNewWindow, "")
		}
	case 'r':
		if hasCard {
			m.target, m.targetWin = c.win.Session, c.win
			m.startPrompt(promptRenameWindow, c.win.Name)
		}
	case 'R':
		if s != nil {
			m.target = s
			m.startPrompt(promptRenameSession, s.Name)
		}
	case 'q':
		switch {
		case !hasCard:
		case c.split:
			return m.run(func() error { return m.act.KillPane(c.pane) }), true
		default:
			return m.run(func() error { return m.act.KillWindow(c.win) }), true
		}
	case 'Q':
		if s != nil {
			m.target = s
			m.pending = confirmKillSession
		}
	case 'c', 'C', 'x', 'D', 'e', 'E':
		if t != nil {
			return m.lifecycleKey(string(l), t), true
		}
	default:
		return nil, false
	}
	return nil, true
}

func (m *model) startPrompt(k promptKind, value string) {
	m.pending = k
	m.prompt.SetValue(value)
	m.prompt.CursorEnd()
	m.prompt.Focus()
}

func (m *model) endPrompt() {
	m.pending = promptNone
	m.label = ""
	m.prompt.Blur()
	m.prompt.SetValue("")
}

func (m model) promptKey(msg tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	kind, s, w, dir, t := m.pending, m.target, m.targetWin, m.targetDir, m.targetWT
	if isConfirm(kind) {
		m.endPrompt()
		if msg.String() != "y" && msg.String() != "Y" {
			return m, nil
		}
		switch kind {
		case confirmKillSession:
			return m, m.run(func() error { return m.act.KillSession(s) })
		case confirmDelete:
			cmd := m.delete(t, s)
			return m, cmd
		case confirmEnvRefresh:
			return m, m.envRefresh(t, m.targetHere)
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
		case promptNewWorktree:
			if name = strings.TrimSpace(name); name == "" {
				return m, nil
			}
			cmd := m.newWorktree(t, name, m.targetFrom)
			return m, cmd
		case promptRepurpose:
			if name = strings.TrimSpace(name); name == "" {
				return m, nil
			}
			cmd := m.repurpose(t, name)
			return m, cmd
		case promptNewWindow:
			// An empty name keeps tmux's automatic naming. In a remote
			// root rw open runs (ssh): keys wait meanwhile.
			m.busy = opening(m.act, dir, "window")
			return m, m.run(func() error { return m.act.NewWindow(s, dir, name) })
		case promptNewSession:
			if name == "" {
				return m, nil
			}
			m.busy = opening(m.act, dir, name)
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

// opening is the busy line while a window or session is created: "opening
// NAME remote …" when dir is in a remote root (rw open runs over ssh), else
// "opening NAME …". dir "" (a session's active pane directory) is resolved
// by the action itself, so it reads as local here.
func opening(a state.Actions, dir, name string) string {
	if dir != "" && a.RootRemote(dir) {
		return "opening " + name + " remote …"
	}
	return "opening " + name + " …"
}

// run performs a stay-open action, then reloads even when the action
// failed: a kill can report an error after it killed. The action's error
// wins over a reload error; a failed reload keeps the old snapshot.
func (m model) run(f func() error) tea.Cmd {
	a := m.act
	return func() tea.Msg { return reload(a, f(), "") }
}

// reload is the actionMsg after an action that ended with actErr.
func reload(a state.Actions, actErr error, status string) actionMsg {
	snap, err := a.Load()
	if err != nil {
		snap = nil
	}
	if actErr != nil {
		err, status = actErr, ""
	}
	return actionMsg{snap: snap, err: err, status: status}
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

// filterChip is the repo filter's indicator, shown when any worktree was
// discovered: All in the panes chip colours, or the repo on its badge
// shade (D80).
func (m model) filterChip() filterChip {
	if !m.hasRepos() {
		return filterChip{}
	}
	if b, ok := m.badges[m.repo]; ok && m.repo != "" {
		return filterChip{text: m.repo, fg: b.fg, bg: b.bg}
	}
	return filterChip{text: "All", fg: cText, bg: panesChipBg}
}
