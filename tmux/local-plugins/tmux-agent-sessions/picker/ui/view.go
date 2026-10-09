package ui

import (
	"strings"

	"agentpicker/state"
)

// render draws the whole screen, top to bottom (D18): the card grid, the
// session list, the input line between two rules (D44). No header, no key
// hints. heights decides how the rows are shared.
func (m model) render() string {
	w, h := m.w, m.h
	lines := make([]string, 0, h)

	gridH, _, rules := m.heights()
	if gridH >= cardRows+2 {
		lines = append(lines, renderGrid(m.cards, m.sel, m.gridTop, w, gridH, m.snap.Now)...)
	} else {
		// Less than one card row fits: no grid (default).
		for range gridH {
			lines = append(lines, strings.Repeat(" ", w))
		}
	}

	lines = append(lines, m.renderList()...)
	if rules > 0 {
		lines = append(lines, renderRule(w), m.renderInput(), renderRule(w))
	} else {
		lines = append(lines, m.renderInput())
	}
	return strings.Join(lines, "\n")
}

// renderList draws exactly listHeight rows (listRows when the screen has
// room, D35). The list runs bottom up, so with fewer matches the empty
// rows sit at the top.
func (m model) renderList() []string {
	memW := m.memWidth()
	fullW := 0
	if m.fullRepo {
		fullW = m.repoW
	}
	rows := m.listHeight()
	n := len(m.matches)
	first, shown := m.top, min(n, rows)
	out := make([]string, 0, rows)
	for range rows - shown {
		out = append(out, renderEmptyRow(m.w))
	}
	for i := first; i < first+shown; i++ {
		var r listRow
		switch x := m.rows[m.matches[i]].(type) {
		case *state.Session:
			r = newSessionRow(x, m.pos[i])
		case *state.Worktree:
			r = newWorktreeRow(x, m.pos[i], m.repoHit[i], m.badges[x.Repo], fullW)
		}
		out = append(out, renderRow(r, memW, m.w, i == m.cur, m.snap.Now))
	}
	return out
}

// memWidth is the memory column's width, shared by every session row: the
// widest session memory. Worktree rows have no memory column (D78).
func (m model) memWidth() int {
	if m.mode == modeWorktrees {
		return 0
	}
	w := 5
	for _, s := range m.snap.Sessions {
		w = max(w, width(memLabel(s.Members())))
	}
	return w
}

func (m model) renderInput() string {
	const indent = "  "
	var left string
	switch {
	case m.err != nil:
		left = indent + paint(oneLine(m.err.Error()), errorFg, "", false)
	case m.pending == confirmKillSession:
		left = indent + paint("kill session "+m.target.Name+"? ", promptFg, "", false) +
			paint("y/N", cText, "", true)
	case m.pending != promptNone:
		left = indent + paint(promptLabels[m.pending], promptFg, "", false) + m.prompt.View()
	default:
		left = indent + m.query.View()
	}
	var chip filterChip
	if m.pending == promptNone && m.err == nil {
		chip = m.filterChip()
	}
	return renderInputLine(left, chip, m.countText(), m.armed, m.w)
}
