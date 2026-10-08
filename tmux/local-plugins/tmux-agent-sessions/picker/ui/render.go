package ui

import (
	"fmt"
	"strings"

	"agentpicker/state"
)

// chipColored renders text on a coloured background with one column of
// padding on each side.
func chipColored(text, fg, bg string, selected bool) string {
	return paint(" "+text+" ", tone(fg, selected), tone(bg, selected), false)
}

// stateChip is a status chip: dark-shade text, the age (when set) a lighter
// shade of it, on the state's background (D49).
func stateChip(text, age string, st state.State, selected bool) string {
	bg := tone(stateBg[st], selected)
	if age == "" {
		return paint(" "+text+" ", tone(stateTextFg[st], selected), bg, false)
	}
	return paint(" "+text+" ", tone(stateTextFg[st], selected), bg, false) +
		paint(age+" ", tone(stateAgeFg[st], selected), bg, false)
}

// statusChip is a card's agent chip: `claudef <icon> 5m`. The icon is
// always followed by a space, in case the glyph spills over.
func statusChip(p *state.Pane, now int64, selected bool) string {
	st := paneState(p)
	return stateChip(runtimeLabel(p.AgentKind)+" "+stateIcon[st], fmtAge(now, stateAt(p)), st, selected)
}

// rowChipLabel is the word on a row's status chip (D57).
var rowChipLabel = map[state.State]string{
	state.StateWorking:  "Working",
	state.StateAwaiting: "Awaiting",
	state.StateDone:     "Done",
}

// aggChip is a row's status chip: `2 Working 5m`, or `2 <icon> 5m` when
// icons is set.
func aggChip(a agg, now int64, icons, selected bool) string {
	label := rowChipLabel[a.state]
	if icons || label == "" {
		label = stateIcon[a.state]
	}
	return stateChip(fmt.Sprintf("%d %s", a.count, label), fmtAge(now, a.at), a.state, selected)
}

// Fixed widths of a row's agents section and the separator around it.
const (
	agentsW = 8 // `<bot> NN AGE`: glyph, space, two-digit count, space, age up to 3
	sepW    = 3 // ` │ `
)

// agentsCell is a row's agents section, always agentsW columns: `<bot> N
// age`, or `<bot> 0` with no age for a session without agents (D55). The
// count is bold on the selected row; the age is a step dimmer than it.
func agentsCell(n int, at, now int64, bg string, selected bool) string {
	countFg, timeFg := memFg, ageFg
	if selected {
		countFg, timeFg = cText, ageSelFg
	}
	count := fmt.Sprintf("%s %d", botIcon, min(n, 99))
	cell := paint(count, countFg, bg, selected)
	w := width(count)
	if n > 0 {
		age := fmtAge(now, at)
		cell += paint(" ", "", bg, false) + paint(age, timeFg, bg, false)
		w += 1 + width(age)
	}
	return cell + paint(strings.Repeat(" ", max(0, agentsW-w)), "", bg, false)
}

// cardMem is a card's memory label: plain text, no cell (D55).
func cardMem(label string, selected bool) string {
	if label == "" {
		return ""
	}
	return paint(label, tone(memFg, selected), "", false)
}

// cardSubtitle is a card's second line (D53): the agent's session name, or
// the empty-chat placeholder, else the running command of the agent pane
// or, for a window without an agent, of its first pane.
func cardSubtitle(c card, iw int, selected bool) string {
	text := tone(cText, selected)
	p := c.pane
	if p != nil && paneState(p) != state.StateNone {
		if p.AgentEmpty {
			return paint(truncate("Empty chat", iw), tone(dimFg, selected), "", false)
		}
		if name := oneLine(p.AgentName); name != "" {
			return paint(truncate(name, iw), text, "", false)
		}
	} else if len(c.win.Panes) > 0 {
		p = c.win.Panes[0]
	}
	if p == nil {
		return ""
	}
	cmd, dim := paneCommand(p)
	fg := commandFg
	if dim {
		fg = shellCmdFg
	}
	return paint(truncate(cmd, iw), tone(fg, selected), "", false)
}

// cardContent is the content rows of a card, iw columns wide at most
// (D51-D54, D58): the header, the subtitle, then the pane count chip, the
// card's agent (if any) and the window's memory.
func cardContent(c card, iw int, selected bool, now int64) []string {
	index := fmt.Sprint(c.win.Index)
	if c.split {
		index = fmt.Sprintf("%d.%d", c.win.Index, c.pane.Index)
	}
	idx := paint(index, tone(indexFg, selected), "", selected)
	name := truncate(oneLine(c.win.Name), iw-width(index)-1)
	header := idx + " " + paint(name, tone(cText, selected), "", selected)

	n := len(c.win.Panes)
	label := fmt.Sprintf("%d panes", n)
	if n == 1 {
		label = "1 pane"
	}
	items := []string{chipColored(label, cText, panesChipBg, selected)}
	if c.pane != nil && paneState(c.pane) != state.StateNone {
		items = append(items, statusChip(c.pane, now, selected))
	}
	if m := memLabel(c.win.Panes); m != "" {
		items = append(items, cardMem(m, selected))
	}
	lines := []string{header, cardSubtitle(c, iw, selected)}
	lines = append(lines, flow(items, iw)...)
	for len(lines) < cardRows {
		lines = append(lines, "")
	}
	return lines
}

// flow wraps items (chips) into lines of at most w columns, one space
// apart. An item wider than a line gets a line of its own, truncated.
func flow(items []string, w int) []string {
	var lines []string
	cur, curW := "", 0
	for _, it := range items {
		iw := width(it)
		switch {
		case curW == 0:
			cur, curW = it, iw
		case curW+1+iw <= w:
			cur += " " + it
			curW += 1 + iw
		default:
			lines = append(lines, cur)
			cur, curW = it, iw
		}
	}
	if curW > 0 {
		lines = append(lines, cur)
	}
	for i, l := range lines {
		if width(l) > w {
			lines[i] = padRight(l, w)
		}
	}
	return lines
}

// cardBox draws content inside a rounded border, h rows tall in total.
func cardBox(content []string, cw, h int, selected bool) []string {
	bc := tone(borderRest, false)
	if selected {
		bc = borderSel
	}
	iw := cw - 4
	out := []string{paint("╭"+strings.Repeat("─", cw-2)+"╮", bc, "", false)}
	side := paint("│", bc, "", false)
	for i := 0; i < h-2; i++ {
		line := ""
		if i < len(content) {
			line = content[i]
		}
		out = append(out, side+" "+padRight(line, iw)+" "+side)
	}
	return append(out, paint("╰"+strings.Repeat("─", cw-2)+"╯", bc, "", false))
}

// gridLayout places cards in rows for a given width.
type gridLayout struct {
	cols    int
	widths  []int
	content [][]string // per card
	rowH    []int      // per grid row, borders included
}

func layoutGrid(cards []card, w, sel int, now int64) gridLayout {
	g := gridLayout{cols: gridCols(w)}
	g.widths = cardWidths(w, g.cols)
	for i, c := range cards {
		col := i % g.cols
		lines := cardContent(c, g.widths[col]-4, i == sel, now)
		g.content = append(g.content, lines)
		if col == 0 {
			g.rowH = append(g.rowH, 0)
		}
		r := len(g.rowH) - 1
		g.rowH[r] = max(g.rowH[r], len(lines)+2)
	}
	return g
}

// visible is how many grid rows from row top show in full within h lines,
// and whether the next row peeks out under them (D36). At most maxCardRows
// rows show in full. When rows remain below, the peek (peekRows lines)
// takes its room from the full rows, but the first full row always shows,
// clipped if it is taller than h.
func (g gridLayout) visible(top, h int) (full int, peek bool) {
	used := 0
	for r := top; r < len(g.rowH) && full < maxCardRows; r++ {
		if full > 0 && used+g.rowH[r] > h {
			break
		}
		used += g.rowH[r]
		full++
	}
	if top+full >= len(g.rowH) {
		return full, false
	}
	for full > 1 && used+peekRows > h {
		full--
		used -= g.rowH[top+full]
	}
	return full, used+peekRows <= h
}

// renderGrid draws the visible grid rows from row top down, then the peek
// of the next row when there is one, padded or clipped to h lines.
func renderGrid(cards []card, sel, top, w, h int, now int64) []string {
	var out []string
	if len(cards) > 0 {
		g := layoutGrid(cards, w, sel, now)
		full, peek := g.visible(top, h)
		last := top + full
		if peek {
			last++
		}
		gap := strings.Repeat(" ", cardGap)
		for r := top; r < last; r++ {
			rowLines := make([]string, g.rowH[r])
			for col := 0; col < g.cols; col++ {
				i := r*g.cols + col
				var box []string
				if i < len(cards) {
					box = cardBox(g.content[i], g.widths[col], g.rowH[r], i == sel)
				}
				for k := range rowLines {
					if col > 0 {
						rowLines[k] += gap
					}
					if box != nil {
						rowLines[k] += box[k]
					} else {
						rowLines[k] += strings.Repeat(" ", g.widths[col])
					}
				}
			}
			if r == top+full { // the peek
				rowLines = rowLines[:peekRows]
			}
			out = append(out, rowLines...)
		}
	}
	if len(out) > h {
		out = out[:h]
	}
	for len(out) < h {
		out = append(out, "")
	}
	for i := range out {
		out[i] = padRight(out[i], w)
	}
	return out
}

// sessionRow is what a session list row shows.
type sessionRow struct {
	name     string
	pos      []int // matched rune indexes, ascending
	chips    []agg // Working, Awaiting, Done with a non-zero count (D55)
	agents   int   // all agents in the session
	agentsAt int64 // newest state change among them
	mem      string
}

func newSessionRow(s *state.Session, pos []int) sessionRow {
	panes := sessionPanes(s)
	n, at := agentSummary(panes)
	return sessionRow{name: oneLine(s.Name), pos: pos, chips: aggregate(panes, rowOrder),
		agents: n, agentsAt: at, mem: memLabel(panes)}
}

// highlightName styles name, marking matched runes. name may already be
// truncated: its "…" tail is never a match.
func highlightName(name string, pos []int, fg, bg string, bold bool) string {
	if len(pos) == 0 {
		return paint(name, fg, bg, bold)
	}
	hit := make(map[int]bool, len(pos))
	for _, p := range pos {
		hit[p] = true
	}
	var b strings.Builder
	var run []rune
	runHit := false
	flush := func() {
		if len(run) == 0 {
			return
		}
		if runHit {
			b.WriteString(paint(string(run), matchFg, bg, true))
		} else {
			b.WriteString(paint(string(run), fg, bg, bold))
		}
		run = run[:0]
	}
	for i, r := range []rune(name) {
		h := hit[i] && r != '…'
		if h != runHit {
			flush()
			runHit = h
		}
		run = append(run, r)
	}
	flush()
	return b.String()
}

// renderSessionRow draws one list row, w columns wide: gutter and name at
// the left, then three sections pushed to the right edge, divided by thin
// rules (D55): the status chips (the only variable width), the agents
// section and the memory, both of fixed width so they line up on every
// row. A long name is truncated before chips are dropped. icons shows the
// chips as icons instead of words (D57).
func renderSessionRow(r sessionRow, memW, w int, icons, selected bool, now int64) string {
	bg := panelBg
	if selected {
		bg = selectBg
	}
	mark := " "
	if selected {
		mark = "▌"
	}
	gutter := paint(mark, gutterMark, gutterBg, false)
	sep := paint(" │ ", sepFg, bg, false)

	chips := make([]string, len(r.chips))
	for i, a := range r.chips {
		chips[i] = aggChip(a, now, icons, true)
	}
	chipsW := func(n int) int {
		total := max(0, n-1)
		for _, c := range chips[:n] {
			total += width(c)
		}
		return total
	}
	// gutter, a leading space and at least one space after the name; the
	// right edge keeps one space after the memory.
	avail := w - 3 - 2*sepW - agentsW - memW - 1
	nameW := width(r.name)
	n := len(chips)
	for n > 0 && avail-chipsW(n) < min(nameW, 12) {
		n--
	}
	name := truncate(r.name, avail-chipsW(n))

	line := gutter + paint(" ", "", bg, false) +
		highlightName(name, r.pos, cText, bg, selected)
	right := ""
	for i, c := range chips[:n] {
		if i > 0 {
			right += paint(" ", "", bg, false)
		}
		right += c
	}
	memFgc := memFg
	if selected {
		memFgc = cText
	}
	right += sep + agentsCell(r.agents, r.agentsAt, now, bg, selected) + sep +
		paint(strings.Repeat(" ", max(0, memW-width(r.mem)))+r.mem+" ", memFgc, bg, selected)
	if fill := w - width(line) - width(right); fill > 0 {
		line += paint(strings.Repeat(" ", fill), "", bg, false)
	}
	return padRight(line+right, w)
}

func renderEmptyRow(w int) string {
	return paint(" ", "", gutterBg, false) + paint(strings.Repeat(" ", max(0, w-1)), "", panelBg, false)
}

// renderRule is the horizontal rule above and below the input line, in the
// card border colour (D44).
func renderRule(w int) string {
	return paint(strings.Repeat("─", w), borderRest, "", false)
}

// renderInputLine draws left (query, prompt or error) with the match count
// and the prefix cell at the right edge (D20).
func renderInputLine(left, count string, armed bool, w int) string {
	cellBg := cellRest
	if armed {
		cellBg = cellArmed
	}
	right := paint(count, countFg, "", false) + " " + paint("  ", "", cellBg, false)
	room := w - width(right)
	return padRight(padRight(left, room)+right, w)
}
