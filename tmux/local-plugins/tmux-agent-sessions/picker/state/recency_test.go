package state

import "testing"

// A session's recency counts its agents' state changes, so a restored
// session whose agent just finished outranks one visited earlier (D95).
func TestSessionRecencyCountsAgentState(t *testing.T) {
	pane := func(focus, stateAt, agentAt int64) *Pane {
		return &Pane{FocusAt: focus, StateAt: stateAt, AgentAt: agentAt}
	}
	cases := []struct {
		name string
		s    *Session
		want int64
	}{
		{"nothing stamped", &Session{Windows: []*Window{{Panes: []*Pane{pane(0, 0, 0)}}}}, 0},
		{"attach only", &Session{LastAttached: 10, Windows: []*Window{{Panes: []*Pane{pane(0, 0, 0)}}}}, 10},
		{"focus newer", &Session{LastAttached: 10, Windows: []*Window{{Panes: []*Pane{pane(20, 0, 0)}}}}, 20},
		{"state newest", &Session{LastAttached: 10, Windows: []*Window{{Panes: []*Pane{pane(20, 30, 0)}}}}, 30},
		{"agent_at when no state_at", &Session{Windows: []*Window{{Panes: []*Pane{pane(0, 0, 25)}}}}, 25},
		{"older agent loses", &Session{LastAttached: 40, Windows: []*Window{{Panes: []*Pane{pane(0, 30, 0)}}}}, 40},
	}
	for _, c := range cases {
		if got := c.s.Recency(); got != c.want {
			t.Errorf("%s: Recency = %d, want %d", c.name, got, c.want)
		}
	}
	// A worktree with such a session uses it over its git mtime.
	w := &Worktree{ActiveAt: 99, Session: &Session{Windows: []*Window{{Panes: []*Pane{pane(0, 30, 0)}}}}}
	if got := w.Recency(); got != 30 {
		t.Errorf("worktree Recency = %d, want 30", got)
	}
	w.Session = &Session{}
	if got := w.Recency(); got != 99 {
		t.Errorf("unstamped session should fall back to mtime, got %d", got)
	}
}
