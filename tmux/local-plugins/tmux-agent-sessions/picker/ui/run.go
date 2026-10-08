// Package ui is the agent picker's Bubble Tea program: the card grid, the
// session list and the input line described in "Picker" of
// docs/notes/tmux-agent-sessions.md.
package ui

import (
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
	// A forced profile means no terminal colour or background queries. The
	// 50 ms escape timeout is Bubble Tea's default (uv.DefaultEscTimeout).
	// No mouse: View.MouseMode stays MouseModeNone.
	p := tea.NewProgram(newModel(a, snap, nil), tea.WithColorProfile(colorprofile.TrueColor))
	_, err = p.Run()
	return err
}
