// Package ui is the agent picker's Bubble Tea program: the card grid, the
// session list and the input line described in "Picker" of
// docs/notes/tmux-agent-sessions.md.
package ui

import (
	"fmt"
	"io"
	"strings"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"

	"agentpicker/state"
)

// Run loads a snapshot and runs the picker in the alt screen until the user
// closes it or an exiting action (switch, create) succeeds. A failed first
// load is returned without opening the picker.
func Run(a state.Actions) error {
	snap, err := a.Load()
	if err != nil {
		return err
	}
	m := newModel(a, snap, nil)
	m.async = true
	// A forced profile means no terminal colour or background queries. The
	// 50 ms escape timeout is Bubble Tea's default (uv.DefaultEscTimeout).
	// No mouse: View.MouseMode stays MouseModeNone.
	p := tea.NewProgram(m, tea.WithColorProfile(colorprofile.TrueColor))
	_, err = p.Run()
	return err
}

// List writes the list as the picker would open it, one row per line, top
// to bottom, then the tab order: `agent-picker --list`, for tests and
// debugging. Heavy symbols are probed inline. Columns are tab-separated:
//
//	wt   REPO BRANCH-OR-COMMIT DIR SESSION-OR-- MARKERS-OR--
//	sess NAME
//	tabs All REPO...
//
// A worktree without a session is dim in the picker; its SESSION is "-".
func List(a state.Actions, w io.Writer) error {
	snap, err := a.Load()
	if err != nil {
		return err
	}
	m := newModel(a, snap, nil)
	for _, r := range m.rows {
		switch x := r.(type) {
		case *state.Session:
			fmt.Fprintf(w, "sess\t%s\n", x.Name)
		case *state.Worktree:
			sess := "-"
			if x.Session != nil {
				sess = x.Session.Name
			}
			var heavy, ms []string
			if !x.Missing {
				heavy = probeHeavy(x.Root)
			}
			for _, mk := range rowMarkers(x, heavy) {
				ms = append(ms, markerWord(mk))
			}
			markers := strings.Join(ms, ",")
			if markers == "" {
				markers = "-"
			}
			fmt.Fprintf(w, "wt\t%s\t%s\t%s\t%s\t%s\n", x.Repo, rowLabel(x), x.Name, sess, markers)
		}
	}
	fmt.Fprintf(w, "tabs\tAll\t%s\n", strings.Join(m.repoOrder, "\t"))
	return nil
}

// markerWord names a marker in --list output.
func markerWord(mk marker) string {
	if mk.text == lockIcon {
		return "locked"
	}
	return mk.text
}
