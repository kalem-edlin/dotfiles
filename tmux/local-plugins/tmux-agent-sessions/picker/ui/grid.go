package ui

import "agentpicker/state"

const (
	cardMinWidth = 30
	cardGap      = 1
	cardRows     = 3 // content rows of a plain card
	maxCardRows  = 3 // full grid rows shown at once (D36)
	peekRows     = 2 // top border and first content line of the next row (D36)
	listRows     = 6 // session list height (D35)
)

// card is one grid cell (D51). A window with two or more agent panes has
// one split card per agent pane (pane set, split true). Any other window
// has one window card; its pane is the window's single agent pane, or nil
// when it has none. In worktree mode only member panes count: a window
// shows when one of its panes is a member, and a member agent pane is the
// only kind that gets a card or fills pane.
type card struct {
	win   *state.Window
	pane  *state.Pane
	lead  *state.Pane // the window's first member pane, the subtitle of a card without an agent
	split bool
}

// id identifies the selection across reloads.
func (c card) id() string {
	if c.split {
		return c.pane.ID
	}
	return c.win.ID
}

// buildCards lays out the cards of windows, counting only the panes member
// accepts. A window with panes but no member pane gets no card.
func buildCards(windows []*state.Window, member func(*state.Pane) bool) []card {
	var out []card
	for _, w := range windows {
		var lead *state.Pane
		var agents []*state.Pane
		for _, p := range w.Panes {
			if !member(p) {
				continue
			}
			if lead == nil {
				lead = p
			}
			if paneState(p) != state.StateNone {
				agents = append(agents, p)
			}
		}
		if lead == nil && len(w.Panes) > 0 {
			continue
		}
		if len(agents) >= 2 {
			for _, p := range agents {
				out = append(out, card{win: w, pane: p, lead: lead, split: true})
			}
			continue
		}
		c := card{win: w, lead: lead}
		if len(agents) == 1 {
			c.pane = agents[0]
		}
		out = append(out, c)
	}
	return out
}

func anyPane(*state.Pane) bool { return true }

func sessionCards(s *state.Session) []card { return buildCards(s.Windows, anyPane) }

func worktreeCards(t *state.Worktree) []card {
	return buildCards(t.Windows, func(p *state.Pane) bool { return p.Worktree == t })
}

// rowCards is the grid for a list row, nil for none.
func rowCards(r state.Row) []card {
	switch r := r.(type) {
	case *state.Session:
		return sessionCards(r)
	case *state.Worktree:
		return worktreeCards(r)
	}
	return nil
}

// lastFocusedPane is the pane with the newest @pane_focus_at, or nil when
// none has one. A tie goes to the first in pane order.
func lastFocusedPane(panes []*state.Pane) *state.Pane {
	var best *state.Pane
	for _, p := range panes {
		if p.FocusAt == 0 {
			continue
		}
		if best == nil || p.FocusAt > best.FocusAt {
			best = p
		}
	}
	return best
}

func activePane(w *state.Window) *state.Pane {
	for _, p := range w.Panes {
		if p.Active {
			return p
		}
	}
	if len(w.Panes) > 0 {
		return w.Panes[0]
	}
	return nil
}

func activeWindow(s *state.Session) *state.Window {
	for _, w := range s.Windows {
		if w.Active {
			return w
		}
	}
	if len(s.Windows) > 0 {
		return s.Windows[0]
	}
	return nil
}

// defaultPane is the pane the grid starts on: the row's most recently
// focused member pane. Without one, a session falls back to its active
// window's active pane, and a worktree to a member pane that is active in
// an active window of an attached session.
func defaultPane(r state.Row) *state.Pane {
	if p := lastFocusedPane(r.Members()); p != nil {
		return p
	}
	switch r := r.(type) {
	case *state.Session:
		if w := activeWindow(r); w != nil {
			return activePane(w)
		}
	case *state.Worktree:
		for _, p := range r.Panes {
			if p.Active && p.Window.Active && p.Window.Session.Attached {
				return p
			}
		}
	}
	return nil
}

// defaultCard returns the index in cards of the card holding p, or 0 when
// p is nil or has no card. A pane without a card of its own (a shell
// beside split agent cards) falls to its window's first card.
func defaultCard(cards []card, p *state.Pane) int {
	if p == nil {
		return 0
	}
	first := -1
	for i, c := range cards {
		if c.win != p.Window {
			continue
		}
		if !c.split || c.pane == p {
			return i
		}
		if first < 0 {
			first = i
		}
	}
	return max(first, 0)
}

// gridCols is 2, or 1 when half the width (less the gap) is under the
// card minimum (D41).
func gridCols(w int) int {
	if (w-cardGap)/2 >= cardMinWidth {
		return 2
	}
	return 1
}

// cardWidths shares the width between the columns; the leftmost columns
// take the remainder.
func cardWidths(w, cols int) []int {
	avail := w - (cols-1)*cardGap
	out := make([]int, cols)
	for i := range out {
		out[i] = avail / cols
		if i < avail%cols {
			out[i]++
		}
	}
	return out
}
