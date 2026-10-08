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
// when it has none.
type card struct {
	win   *state.Window
	pane  *state.Pane
	split bool
}

// id identifies the selection across reloads.
func (c card) id() string {
	if c.split {
		return c.pane.ID
	}
	return c.win.ID
}

// agentPanes are the window's panes with a live agent, in pane order.
func agentPanes(w *state.Window) []*state.Pane {
	var out []*state.Pane
	for _, p := range w.Panes {
		if paneState(p) != state.StateNone {
			out = append(out, p)
		}
	}
	return out
}

func buildCards(s *state.Session) []card {
	if s == nil {
		return nil
	}
	var out []card
	for _, w := range s.Windows {
		agents := agentPanes(w)
		if len(agents) >= 2 {
			for _, p := range agents {
				out = append(out, card{win: w, pane: p, split: true})
			}
			continue
		}
		c := card{win: w}
		if len(agents) == 1 {
			c.pane = agents[0]
		}
		out = append(out, c)
	}
	return out
}

// newestAgentPane is the pane whose agent changed state most recently
// (@agent_at, D15), or nil.
func newestAgentPane(panes []*state.Pane) *state.Pane {
	var best *state.Pane
	for _, p := range panes {
		if p.Remote || p.State == state.StateNone || p.AgentAt == 0 {
			continue
		}
		if best == nil || p.AgentAt > best.AgentAt {
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

// defaultPane is the D15 selection: the newest agent pane, else the active
// window's active pane.
func defaultPane(s *state.Session) *state.Pane {
	if p := newestAgentPane(sessionPanes(s)); p != nil {
		return p
	}
	if w := activeWindow(s); w != nil {
		return activePane(w)
	}
	return nil
}

// defaultCard returns the index of the D15 card in cards.
func defaultCard(s *state.Session, cards []card) int {
	if s == nil {
		return 0
	}
	p := defaultPane(s)
	if p == nil {
		return 0
	}
	for i, c := range cards {
		if (c.split && c.pane == p) || (!c.split && c.win == p.Window) {
			return i
		}
	}
	return 0
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
