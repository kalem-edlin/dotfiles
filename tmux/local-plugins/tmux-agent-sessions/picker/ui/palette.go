package ui

import (
	"fmt"

	"charm.land/lipgloss/v2"

	"agentpicker/state"
)

// Catppuccin mocha.
const (
	cBase      = "#1e1e2e"
	cCrust     = "#11111b"
	cSurface0  = "#313244"
	cSurface1  = "#45475a"
	cSurface2  = "#585b70"
	cOverlay0  = "#6c7086"
	cOverlay1  = "#7f849c"
	cOverlay2  = "#9399b2"
	cSubtext0  = "#a6adc8"
	cSubtext1  = "#bac2de"
	cText      = "#cdd6f4"
	cLavender  = "#b4befe"
	cBlue      = "#89b4fa"
	cGreen     = "#a6e3a1"
	cPeach     = "#fab387"
	cRed       = "#f38ba8"
	cMauve     = "#cba6f7"
	cRosewater = "#f5e0dc"
)

// Derived colours. Terminals have no alpha, so "lighter panel" and
// "transparent white highlight" are pre-blended against the base.
var (
	panelBg     = blend(cBase, cSurface0, 0.7)
	selectBg    = blend(panelBg, cText, 0.15)
	gutterBg    = cCrust
	gutterMark  = cRosewater
	matchFg     = cRed   // fzf hl in the user's catppuccin FZF_DEFAULT_OPTS
	countFg     = cMauve // fzf info colour
	promptFg    = cMauve
	errorFg     = cRed
	cellRest    = cGreen
	cellArmed   = cRed
	ageFg       = cOverlay1 // age outside a chip, unselected row
	ageSelFg    = cSubtext0 // the same on the selected row, a step under its bold count
	panesChipBg = cSurface1
	sepFg       = cSurface2 // row section separators, the rule colour (D55)
	dimFg       = cOverlay1 // the empty-chat placeholder (D59)
	botIcon     = "\ue1bb"  // Lucide bot (U+E1BB), before the agent count (D55)
	borderRest  = cSurface2
	borderSel   = cText
	memFg       = cSubtext0
	shellCmdFg  = cOverlay1
	commandFg   = cSubtext1
	indexFg     = cLavender
)

// dimAmount is how far an unselected card's colours move toward the base
// (D27). Tune in the live trial.
const dimAmount = 0.5

// Status chip backgrounds and Lucide icons (D19, D28). The backgrounds are
// catppuccin pastels again (D60), with a darker shade of each as text (Q34).
var stateBg = map[state.State]string{
	state.StateDone:     cGreen,
	state.StateWorking:  cBlue,
	state.StateAwaiting: cPeach,
	state.StateIdle:     cOverlay0,
}

// Chip count, label and icon text: a darker shade of the chip's own
// background.
var stateTextFg = map[state.State]string{
	state.StateDone:     "#465f44",
	state.StateWorking:  "#394c69",
	state.StateAwaiting: "#694b39",
	state.StateIdle:     "#2d2f38",
}

// Chip age text: the text shade 30% of the way toward the background, so
// time reads lower in contrast than the count and label.
var stateAgeFg = map[state.State]string{
	state.StateDone:     "#719b6f",
	state.StateWorking:  "#5e7bac",
	state.StateAwaiting: "#ac7a5c",
	state.StateIdle:     "#4a4d5c",
}

var stateIcon = map[state.State]string{
	state.StateDone:     "", // circle-check
	state.StateWorking:  "", // circle-dashed
	state.StateAwaiting: "", // circle-question-mark
	state.StateIdle:     "", // circle-minus
}

type rgb struct{ r, g, b float64 }

func parseHex(s string) rgb {
	var r, g, b uint8
	fmt.Sscanf(s, "#%02x%02x%02x", &r, &g, &b)
	return rgb{float64(r), float64(g), float64(b)}
}

// blend mixes a toward b by t (0 keeps a, 1 gives b), in plain sRGB.
func blend(a, b string, t float64) string {
	x, y := parseHex(a), parseHex(b)
	mix := func(p, q float64) uint8 { return uint8(p + (q-p)*t + 0.5) }
	return fmt.Sprintf("#%02x%02x%02x", mix(x.r, y.r), mix(x.g, y.g), mix(x.b, y.b))
}

// tone returns c unchanged for a selected card, dimmed toward the base for
// any other.
func tone(c string, selected bool) string {
	if selected || c == "" {
		return c
	}
	return blend(c, cBase, dimAmount)
}

// paint renders s with an optional foreground and background ("" leaves
// either unset).
func paint(s, fg, bg string, bold bool) string {
	st := lipgloss.NewStyle()
	if fg != "" {
		st = st.Foreground(lipgloss.Color(fg))
	}
	if bg != "" {
		st = st.Background(lipgloss.Color(bg))
	}
	if bold {
		st = st.Bold(true)
	}
	return st.Render(s)
}
