package ui

import (
	"fmt"
	"path"
	"strings"

	"github.com/charmbracelet/x/ansi"

	"agentpicker/state"
)

// fmtAge formats the time since a state began (D29): 42s, 5m, 3h, 2d, then
// weeks from 7 days. No months.
func fmtAge(now, at int64) string {
	if at == 0 {
		return ""
	}
	d := now - at
	if d < 0 {
		d = 0
	}
	switch {
	case d < 60:
		return fmt.Sprintf("%ds", d)
	case d < 3600:
		return fmt.Sprintf("%dm", d/60)
	case d < 86400:
		return fmt.Sprintf("%dh", d/3600)
	case d < 7*86400:
		return fmt.Sprintf("%dd", d/86400)
	default:
		return fmt.Sprintf("%dw", d/(7*86400))
	}
}

// fmtMem formats a footprint in KiB like v1's fmtmem: whole MiB below 1 GiB
// (at least 1M for a non-zero value), one decimal GiB above.
func fmtMem(kb int64) string {
	if kb < 1048576 {
		m := kb / 1024
		if m < 1 && kb > 0 {
			m = 1
		}
		return fmt.Sprintf("%dM", m)
	}
	return fmt.Sprintf("%.1fG", float64(kb)/1048576)
}

// stateAt is when the pane's state began: @agent_state_at, else @agent_at.
func stateAt(p *state.Pane) int64 { return p.StateSince() }

// paneState normalises a live agent's state; an unknown value counts as
// idle, as in v1.
func paneState(p *state.Pane) state.State {
	if p.Remote || p.State == state.StateNone {
		return state.StateNone
	}
	if _, ok := stateBg[p.State]; !ok {
		return state.StateIdle
	}
	return p.State
}

// rowOrder is the order of a session row's status chips (D55). Idle has no
// row chip.
var rowOrder = []state.State{state.StateWorking, state.StateAwaiting, state.StateDone}

// agg is one aggregated status chip: how many panes are in a state, and
// the newest time one of them entered it.
type agg struct {
	state state.State
	count int
	at    int64
}

func aggregate(panes []*state.Pane, order []state.State) []agg {
	var out []agg
	for _, st := range order {
		a := agg{state: st}
		for _, p := range panes {
			if paneState(p) != st {
				continue
			}
			a.count++
			a.at = max(a.at, stateAt(p))
		}
		if a.count > 0 {
			out = append(out, a)
		}
	}
	return out
}

// agentSummary counts every live agent in panes and finds the newest state
// change among them (0 when none has a time).
func agentSummary(panes []*state.Pane) (n int, at int64) {
	for _, p := range panes {
		if paneState(p) != state.StateNone {
			n++
			at = max(at, stateAt(p))
		}
	}
	return n, at
}

// memLabel sums local pane memory. Remote panes have none: they show
// "remote", after the sum when local panes exist too (as v1 did).
func memLabel(panes []*state.Pane) string {
	var kb int64
	local, remote := false, false
	for _, p := range panes {
		if p.Remote {
			remote = true
			continue
		}
		if p.HasMem {
			local = true
			kb += p.MemKB
		}
	}
	switch {
	case local && remote:
		return fmtMem(kb) + " remote"
	case local:
		return fmtMem(kb)
	case remote:
		return "remote"
	}
	return ""
}

func runtimeLabel(kind string) string {
	switch kind {
	case "claude":
		return "claudef"
	case "pi":
		return "pif"
	case "":
		return "agent"
	}
	return kind
}

var shells = map[string]bool{
	"zsh": true, "bash": true, "sh": true, "fish": true,
	"dash": true, "ksh": true, "tcsh": true, "csh": true, "nu": true,
}

func isShell(cmd string) bool {
	return shells[path.Base(strings.TrimPrefix(cmd, "-"))]
}

// paneCommand is the second card row for a pane without an agent. At a
// shell prompt it is the last command line, dimmed; otherwise the last
// command line (`pnpm branch` where the process is `node`), falling back to
// the process name.
func paneCommand(p *state.Pane) (text string, dim bool) {
	last := oneLine(p.LastCommand)
	if isShell(p.Command) {
		if last != "" {
			return last, true
		}
		return p.Command, true
	}
	if last != "" {
		return last, false
	}
	return p.Command, false
}

func oneLine(s string) string {
	return strings.Join(strings.Fields(s), " ")
}

// truncate cuts plain text to w display columns, ending in "…".
func truncate(s string, w int) string {
	if w <= 0 {
		return ""
	}
	return ansi.Truncate(s, w, "…")
}

func width(s string) int { return ansi.StringWidth(s) }

// padRight pads a (possibly styled) string with spaces to w columns, or
// truncates it.
func padRight(s string, w int) string {
	n := width(s)
	if n > w {
		return ansi.Truncate(s, w, "…")
	}
	return s + strings.Repeat(" ", w-n)
}
