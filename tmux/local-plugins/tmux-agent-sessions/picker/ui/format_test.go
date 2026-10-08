package ui

import (
	"reflect"
	"testing"

	"agentpicker/state"
)

func TestMatch(t *testing.T) {
	m := newMatcher()
	tests := []struct {
		query, name string
		ok          bool
		pos         []int
	}{
		{"", "dotfiles", true, nil},
		{"funnel", "roll-web-funnel-changes", true, []int{9, 10, 11, 12, 13, 14}},
		{"FUNNEL", "roll-web-funnel-changes", true, []int{9, 10, 11, 12, 13, 14}},
		{"web", "Roll-WEB-funnel", true, []int{5, 6, 7}},
		{"zzz", "dotfiles", false, nil},
		{"dtf", "dotfiles", true, []int{0, 2, 3}},
	}
	for _, tt := range tests {
		ok, pos := m.match(tt.query, tt.name)
		if ok != tt.ok || !reflect.DeepEqual(pos, tt.pos) {
			t.Errorf("match(%q, %q) = %v %v, want %v %v", tt.query, tt.name, ok, pos, tt.ok, tt.pos)
		}
	}
}

func TestFmtAge(t *testing.T) {
	tests := []struct {
		ago  int64
		want string
	}{
		{0, "0s"}, {42, "42s"}, {59, "59s"}, {60, "1m"}, {5*60 + 59, "5m"},
		{3600, "1h"}, {3*3600 + 10, "3h"}, {86400, "1d"}, {6*86400 + 3600, "6d"},
		{7 * 86400, "1w"}, {23 * 86400, "3w"}, {400 * 86400, "57w"},
		{-5, "0s"}, // clock skew
	}
	for _, tt := range tests {
		if got := fmtAge(now, now-tt.ago); got != tt.want {
			t.Errorf("fmtAge(%d ago) = %q, want %q", tt.ago, got, tt.want)
		}
	}
	if got := fmtAge(now, 0); got != "" {
		t.Errorf("fmtAge(unset) = %q, want empty", got)
	}
}

func TestStateAtFallback(t *testing.T) {
	p := &state.Pane{State: state.StateDone, AgentAt: now - 90}
	if got := fmtAge(now, stateAt(p)); got != "1m" {
		t.Errorf("AgentAt fallback = %q", got)
	}
	p.StateAt = now - 10
	if got := fmtAge(now, stateAt(p)); got != "10s" {
		t.Errorf("StateAt = %q", got)
	}
}

func TestFmtMem(t *testing.T) {
	tests := []struct {
		kb   int64
		want string
	}{
		{0, "0M"}, {1, "1M"}, {1023, "1M"}, {512 * 1024, "512M"},
		{1048575, "1023M"}, {1048576, "1.0G"}, {1887437, "1.8G"}, {3 * 1048576, "3.0G"},
	}
	for _, tt := range tests {
		if got := fmtMem(tt.kb); got != tt.want {
			t.Errorf("fmtMem(%d) = %q, want %q", tt.kb, got, tt.want)
		}
	}
}

func TestMemLabel(t *testing.T) {
	snap := fixture()
	tests := map[string]string{
		"infra":                   "45M remote",
		"roll-carousels-3":        "1.6G",
		"roll-web-funnel-changes": "1.2G remote",
	}
	for _, s := range snap.Sessions {
		if want, ok := tests[s.Name]; ok {
			if got := memLabel(sessionPanes(s)); got != want {
				t.Errorf("memLabel(%s) = %q, want %q", s.Name, got, want)
			}
		}
	}
	if got := memLabel([]*state.Pane{remote()}); got != "remote" {
		t.Errorf("remote only = %q", got)
	}
}

func TestAggregate(t *testing.T) {
	s := fixture().Sessions[3] // roll-web-funnel-changes
	got := aggregate(sessionPanes(s), rowOrder)
	want := []agg{
		{state.StateWorking, 1, now - 120},
		{state.StateDone, 1, now - 40},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("aggregate = %+v, want %+v", got, want)
	}
}

func TestPaneCommand(t *testing.T) {
	tests := []struct {
		p    *state.Pane
		text string
		dim  bool
	}{
		{shell("zsh", "pnpm test --watch", 0), "pnpm test --watch", true},
		{shell("-zsh", "", 0), "-zsh", true},
		{shell("node", "pnpm  branch\n", 0), "pnpm branch", false},
		{shell("nvim", "", 0), "nvim", false},
	}
	for _, tt := range tests {
		text, dim := paneCommand(tt.p)
		if text != tt.text || dim != tt.dim {
			t.Errorf("paneCommand(%q, %q) = %q %v, want %q %v",
				tt.p.Command, tt.p.LastCommand, text, dim, tt.text, tt.dim)
		}
	}
}

// At most two columns, each half the width; one column when half the
// width is under the 30-column card minimum (D41).
func TestGridGeometry(t *testing.T) {
	for _, tt := range []struct{ w, cols int }{{29, 1}, {30, 1}, {60, 1}, {61, 2}, {80, 2}, {120, 2}, {180, 2}, {400, 2}} {
		if got := gridCols(tt.w); got != tt.cols {
			t.Errorf("gridCols(%d) = %d, want %d", tt.w, got, tt.cols)
		}
		ws := cardWidths(tt.w, tt.cols)
		total := len(ws) - 1
		for _, x := range ws {
			total += x
		}
		if total != tt.w {
			t.Errorf("cardWidths(%d) = %v, sum %d", tt.w, ws, total)
		}
		if ws[len(ws)-1] < min(tt.w, cardMinWidth) || ws[0]-ws[len(ws)-1] > 1 {
			t.Errorf("cardWidths(%d) = %v, want equal halves of at least %d", tt.w, ws, cardMinWidth)
		}
	}
}

func TestBlend(t *testing.T) {
	if got := blend("#000000", "#ffffff", 0.5); got != "#808080" {
		t.Errorf("blend = %s", got)
	}
	if got := tone(cGreen, true); got != cGreen {
		t.Errorf("selected tone = %s", got)
	}
	if got := tone(cGreen, false); got != "#628168" {
		t.Errorf("dim green = %s", got)
	}
}
