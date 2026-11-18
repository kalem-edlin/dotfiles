package ui

import (
	"fmt"
	"os"
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
	// The preview line heads the grid area, with a darker rule under it
	// (D107); the cards take the rest.
	if ph := m.previewH(); ph > 0 && gridH >= ph {
		lines = append(lines, m.renderPreview(), paint(strings.Repeat("─", w), previewRuleFg, "", false))
		gridH -= ph
	}
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
	rows := m.listHeight()
	n := len(m.matches)
	first, shown := m.top, min(n, rows)
	out := make([]string, 0, rows)
	for range rows - shown {
		out = append(out, renderEmptyRow(m.w))
	}
	for i := first; i < first+shown; i++ {
		r := m.listRow(m.rows[m.matches[i]], m.pos[i], m.repoHit[i])
		out = append(out, renderRow(r, memW, m.w, i == m.cur, m.snap.Now))
	}
	return out
}

// listRow is what row r shows, with the query's highlight positions pos and
// whether the query matched its repo.
func (m model) listRow(row state.Row, pos []int, repoHit bool) listRow {
	fullW, badgeW := 0, 0
	if m.hasRepos() {
		badgeW = badgeCodeW
		if m.fullRepo {
			fullW, badgeW = m.repoW, m.repoW
		}
	}
	var r listRow
	switch x := row.(type) {
	case *state.Session:
		r = newSessionRow(x, pos)
		r.markers = sessionMarkers(x)
		// Keep names in line with the branch labels behind the badges.
		r.repo, r.statusOnly = strings.Repeat(" ", badgeW), m.fullRepo
	case *state.Worktree:
		r = newWorktreeRow(x, pos, repoHit, m.badges[x.Repo], fullW)
		r.markers = rowMarkers(x, m.heavy[x.Root])
	}
	return r
}

// memWidth is the memory column's width, shared by every row with a
// session: the widest session memory. Full-repo mode has no memory column.
func (m model) memWidth() int {
	if m.fullRepo {
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
	case m.busy != "":
		left = indent + paint(m.busy, dimFg, "", false)
	case m.err != nil:
		left = indent + paint(oneLine(m.err.Error()), errorFg, "", false)
	case m.pending == confirmKillSession:
		left = indent + paint("kill session "+m.target.Name+"? ", promptFg, "", false) +
			paint("y/N", cText, "", true)
	case isConfirm(m.pending):
		// The label gives way before [y/N] does.
		const yn = "[y/N]"
		room := max(0, m.w-width(indent)-width(yn)-width(m.countText())-4)
		left = indent + paint(truncate(oneLine(m.label)+" ", room), promptFg, "", false) +
			paint(yn, cText, "", true)
	case m.pending != promptNone:
		label := promptLabels[m.pending]
		if label == "" {
			label = m.label
		}
		left = indent + paint(label, promptFg, "", false) + m.prompt.View()
	case m.status != "":
		left = indent + paint(oneLine(m.status), statusFg, "", false)
	default:
		left = indent + m.query.View()
	}
	var chip filterChip
	if m.pending == promptNone && m.err == nil && m.busy == "" && m.status == "" {
		chip = m.filterChip()
	}
	return renderInputLine(left, chip, m.countText(), m.armed, m.w)
}

// renderPreview is the first line of the grid area for a worktree row
// (V7, D106, D107): its directory, then its git state as cells on one
// background, each holding one figure: dirty and untracked counts, lines
// added and deleted, ahead and behind its upstream. Zero cells are dimmed
// rather than dropped, so the row keeps its shape. Neither the branch (the
// list row has it) nor the ports are shown. A missing directory says so
// instead.
func (m model) renderPreview() string {
	t := m.worktree()
	if t == nil {
		return strings.Repeat(" ", m.w)
	}
	items := []string{paint(tildePath(t.Root), commandFg, "", false)}
	g, read := m.git[t.Root]
	switch {
	case t.Missing:
		items = append(items, previewCell(paint("directory missing", errorFg, previewBg, false)))
	case !read:
		items = append(items, previewCell(paint("git …", previewDimFg, previewBg, false)))
	case g.Err != "":
		items = append(items, previewCell(paint("git: "+oneLine(g.Err), errorFg, previewBg, false)))
	default:
		items = append(items,
			previewCount(g.Dirty, "dirty"),
			previewCount(g.Untracked, "untracked"),
			previewLines(g.Added, g.Deleted))
		if g.Upstream {
			items = append(items, previewCell(
				paint(fmt.Sprintf("↑%d ↓%d", g.Ahead, g.Behind), previewValueFg, previewBg, g.Ahead+g.Behind > 0)))
		} else {
			items = append(items, previewCell(paint("no upstream", previewDimFg, previewBg, false)))
		}
	}
	return padRight("  "+strings.Join(items, " "), m.w)
}

// previewCell pads painted text with one background column on each side.
func previewCell(painted string) string {
	pad := paint(" ", "", previewBg, false)
	return pad + painted + pad
}

// previewCount is a `N label` cell: a bold count with its label, or the
// whole cell dimmed when the count is zero.
func previewCount(n int, label string) string {
	if n == 0 {
		return previewCell(paint("0 "+label, previewDimFg, previewBg, false))
	}
	return previewCell(paint(fmt.Sprint(n), previewValueFg, previewBg, true) +
		paint(" "+label, previewLabelFg, previewBg, false))
}

// previewLines is the `+A -D` cell: added lines in green, deleted in red,
// dimmed when both are zero.
func previewLines(added, deleted int) string {
	if added == 0 && deleted == 0 {
		return previewCell(paint("+0 -0", previewDimFg, previewBg, false))
	}
	return previewCell(paint(fmt.Sprintf("+%d", added), cGreen, previewBg, true) +
		paint(" ", "", previewBg, false) +
		paint(fmt.Sprintf("-%d", deleted), cRed, previewBg, true))
}

// tildePath shortens a path under the home directory to ~/...
func tildePath(p string) string {
	if h, err := os.UserHomeDir(); err == nil && h != "" && h != "/" {
		if p == h {
			return "~"
		}
		if rest, ok := strings.CutPrefix(p, h+"/"); ok {
			return "~/" + rest
		}
	}
	return p
}
