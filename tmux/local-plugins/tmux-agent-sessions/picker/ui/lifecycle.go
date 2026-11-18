package ui

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"

	tea "charm.land/bubbletea/v2"

	"agentpicker/state"
)

// Worktree lifecycle keys (B3, task V10-V12, keys per D103, D104): c and
// C create a worktree (from main, or from the row's branch) and go to its
// new session; x repurposes ("cuts") the row's worktree in place, stashing
// a dirty tree; D moves it, or on a main checkout with no linked worktrees
// the whole repo, to the Trash (D102, D105); e refreshes the env files of
// every worktree of the row's repo from a fresh pull in its main checkout,
// and E spreads the row's own files instead, as they are (D109). One prompt
// or one short confirm each. Each runs the wt script
// through state.Actions as a tea.Cmd, so the "running wt ..." line renders
// first; keys wait until it answers.

// lifecycleKey starts C-a c, C, x, D, e or E on worktree row t.
func (m *model) lifecycleKey(k string, t *state.Worktree) tea.Cmd {
	m.targetWT, m.target = t, t.Session
	switch k {
	case "c", "C":
		if t.Missing {
			m.err = fmt.Errorf("worktree directory is missing: %s", t.Root)
			return nil
		}
		m.targetFrom, m.label = "", "new worktree from main: "
		if k == "C" {
			m.targetFrom = t.Branch
			if t.Detached() {
				m.targetFrom = t.Head
			}
			m.label = "new worktree from " + m.targetFrom + ": "
		}
		m.startPrompt(promptNewWorktree, "")
	case "x":
		if t.Main {
			m.err = fmt.Errorf("refusing to repurpose the main worktree: %s", t.Name)
			return nil
		}
		if m.err = refuseChange(t, "repurpose"); m.err != nil {
			return nil
		}
		if t.Missing {
			m.err = fmt.Errorf("worktree directory is missing: %s", t.Root)
			return nil
		}
		m.label = "repurpose " + t.Name + " to branch: "
		m.startPrompt(promptRepurpose, "")
	case "D":
		if m.err = refuseChange(t, "delete"); m.err != nil {
			return nil
		}
		if t.Current && m.nextSession(t.Session) == nil {
			// The client moves to another session before its own is
			// killed (D108); with none it would detach and end the popup.
			m.err = fmt.Errorf("refusing to delete %s: no other session to switch to", t.Name)
			return nil
		}
		// Remote now, from the records read at this key (not the
		// snapshot): a root handed off after the picker loaded still gets
		// the remote confirm (D11).
		m.targetRemote = m.act.RootRemote(t.Root)
		if t.Missing && !m.targetRemote {
			// Nothing on disk to lose, and wt reads no status for it:
			// wt rm prunes the registration or says why it cannot, and
			// deletes a worker copy left from an earlier handoff (D11).
			root, name := t.Root, t.Name
			return m.wt("rm", func(a state.Actions) tea.Msg {
				res, err := a.WorktreeRemove(root, false)
				msg := reload(a, wtRemoveErr(name, err), "pruned "+name+remoteStatus(res.Remote))
				msg.forget = root
				return msg
			})
		}
		if t.Main || t.Locked {
			// The refusals need wt: a main checkout's linked worktrees,
			// a lock's reason.
			root := t.Root
			return m.wt("status", func(a state.Actions) tea.Msg {
				st, err := a.WorktreeStatus(root)
				return wtStatusMsg{st, err}
			})
		}
		m.openDeleteConfirm(t)
	case "e", "E":
		if t.Missing {
			m.err = fmt.Errorf("worktree directory is missing: %s", t.Root)
			return nil
		}
		// On the main row E is e: wt takes main as the source and pulls.
		m.targetHere = k == "E"
		source := "main"
		if m.targetHere {
			source = t.Name
		}
		m.label = "refresh env of every " + t.Repo + " worktree from " + source + "? "
		m.pending = confirmEnvRefresh
	}
	return nil
}

// envRefresh runs wt env-refresh for t's repo (D109): the main checkout
// pulls afresh when its wt.envPull is set, then every linked worktree gets
// the copies with its own ports; with here (C-a E) t itself is the source,
// copied as it is to every other worktree, main included, with no pull. No
// session changes, so the reload keeps the rows; only the preview counts
// may move.
func (m *model) envRefresh(t *state.Worktree, here bool) tea.Cmd {
	root, repo := t.Root, t.Repo
	return m.wt("env-refresh", func(a state.Actions) tea.Msg {
		res, err := a.WorktreeEnvRefresh(root, here)
		if err != nil {
			return reload(a, err, "")
		}
		return reload(a, nil, envRefreshStatus(repo, res))
	})
}

// envRefreshStatus is the green line after wt env-refresh. The files are
// not listed: they are the same set wt new copies, and the line is narrow.
func envRefreshStatus(repo string, r state.WTEnvResult) string {
	noun := "worktrees"
	if r.Refreshed == 1 {
		noun = "worktree"
	}
	s := fmt.Sprintf("env refreshed in %d %s %s from %s", r.Refreshed, repo, noun, filepath.Base(r.Source))
	if r.Pulled {
		s += ", pulled"
	} else {
		s += ", copied only"
	}
	skipped := 0
	for _, w := range r.Worktrees {
		skipped += len(w.Skipped)
	}
	if skipped > 0 {
		s += fmt.Sprintf(", %d symlink(s) skipped", skipped)
	}
	if len(r.Missing) > 0 {
		s += fmt.Sprintf(", %d missing", len(r.Missing))
	}
	return s
}

// refuseChange is the local refusal before repurpose or delete: a row
// whose session has an agent Working. (Repurpose also refuses the main
// worktree; delete leaves main to wt status, D102.)
func refuseChange(t *state.Worktree, verb string) error {
	n := 0
	for _, p := range t.Panes {
		if p.State == state.StateWorking {
			n++
		}
	}
	switch n {
	case 0:
		return nil
	case 1:
		return fmt.Errorf("refusing to %s %s: an agent is working in it", verb, t.Name)
	}
	return fmt.Errorf("refusing to %s %s: %d agents are working in it", verb, t.Name, n)
}

// wt runs f off the UI goroutine with "running wt OP ..." on the input line.
func (m *model) wt(op string, f func(state.Actions) tea.Msg) tea.Cmd {
	m.busy = "running wt " + op + " …"
	a := m.act
	return func() tea.Msg { return f(a) }
}

// newWorktree runs wt new for the repo of row t, then creates the new
// directory's session there and goes to it; the picker exits. Nothing is
// installed. A failure reloads and stays open.
func (m *model) newWorktree(t *state.Worktree, branch, from string) tea.Cmd {
	root := t.Root
	return m.wt("new", func(a state.Actions) tea.Msg {
		res, err := a.WorktreeNew(root, branch, from)
		if err == nil && res.Path == "" {
			err = errors.New("wt new: no path in its reply")
		}
		if err == nil {
			if err = a.CreateSession(state.SessionName(filepath.Base(res.Path)), res.Path); err == nil {
				return exitMsg{}
			}
		}
		return reload(a, err, "")
	})
}

// repurpose runs wt repurpose on t with --stash, so a dirty tree is
// stashed (wt's tagged stash) rather than asked about (D105); the picker
// reloads and shows the result.
func (m *model) repurpose(t *state.Worktree, branch string) tea.Cmd {
	root, name := t.Root, t.Name
	return m.wt("repurpose", func(a state.Actions) tea.Msg {
		res, err := a.WorktreeRepurpose(root, branch)
		msg := reload(a, err, repurposeStatus(name, res))
		msg.forget = root
		return msg
	})
}

// repurposeStatus is the short result line (D105).
func repurposeStatus(name string, r state.WTResult) string {
	s := "repurposed " + name + " to " + r.Branch
	switch {
	case r.StashedChanges == 1:
		s += ", 1 change stashed"
	case r.StashedChanges > 1:
		s += fmt.Sprintf(", %d changes stashed", r.StashedChanges)
	case r.Stashed:
		s += ", changes stashed"
	}
	return s
}

// delete kills s (when t has a session; remote panes close through rw
// first), then runs wt rm on t, which deletes every worker copy of it (rw
// forget, D11) and moves it to the Trash, then starts a background
// resurrect save. A kill failure stops before wt rm. On the client's own
// row the client is switched to the next most recent session first (D108),
// so the kill never leaves it without a session. wt rm gets
// --discard-remote only when the user confirmed a root that was remote at
// key time (openDeleteConfirm); a root that became remote since is refused
// by wt and nothing is deleted.
func (m *model) delete(t *state.Worktree, s *state.Session) tea.Cmd {
	root, name, repo, remote := t.Root, t.Name, t.Repo, m.targetRemote
	var next *state.Session
	if t.Current {
		next = m.nextSession(s)
	}
	return m.wt("rm", func(a state.Actions) tea.Msg {
		if s != nil {
			if next != nil {
				if err := a.Switch(next, nil, nil); err != nil {
					return reload(a, err, "")
				}
			}
			if err := a.KillSession(s); err != nil {
				return reload(a, err, "")
			}
		}
		res, err := a.WorktreeRemove(root, remote)
		if err != nil {
			return reload(a, wtRemoveErr(name, err), "")
		}
		status := "deleted " + name
		if res.Main {
			status = "deleted repo " + repo
		}
		if res.Pruned != "" {
			status = "pruned " + name
		}
		status += remoteStatus(res.Remote)
		if err := a.SaveLayout(); err != nil {
			status += " (" + err.Error() + ")"
		}
		msg := reload(a, nil, status)
		msg.forget = root
		return msg
	})
}

// remoteStatus is the result line's tail for wt rm's rw forget (its
// "remote" reply). Workers are never named (D10).
func remoteStatus(remote string) string {
	switch remote {
	case "deleted":
		return ", remote copy deleted"
	case "pending":
		return ", remote copy deleted on next contact"
	case "kept":
		return ", rw missing, remote copy kept"
	}
	return ""
}

// wtRemoveErr turns wt rm's remote refusal (exit 5, "is remote": the root
// became remote after the confirm) into what to do next; nothing was
// deleted. Other errors pass through; wt's own text says what rw forget
// already did.
func wtRemoveErr(name string, err error) error {
	var we *state.WTError
	if errors.As(err, &we) && we.Code == state.WTRefused && strings.Contains(we.Msg, "is remote") {
		return fmt.Errorf("%s is remote; nothing deleted. C-a D again to confirm deleting its remote copy too", name)
	}
	return err
}

// nextSession is the most recently active session other than s: where the
// client goes before s, its own session, is killed (D108). nil without one.
func (m model) nextSession(s *state.Session) *state.Session {
	var best *state.Session
	for _, o := range m.snap.Sessions {
		if s != nil && o.ID == s.ID {
			continue
		}
		if best == nil || o.Recency() > best.Recency() {
			best = o
		}
	}
	return best
}

// openDeleteConfirm opens the one short delete confirm (D105). A remote
// root says so: rw forget deletes the worker copy, the only current one
// while the worker owns the root (D11, D17).
func (m *model) openDeleteConfirm(t *state.Worktree) {
	m.label = "delete " + t.Name + " to Trash? "
	if t.Main {
		m.label = "delete repo " + t.Repo + " to Trash? "
	}
	if m.targetRemote {
		// Question first: a narrow input line truncates the tail.
		m.label = "delete " + t.Name + "? it is remote; its remote copy, the only current one, goes too "
	}
	m.pending = confirmDelete
}

// deleteConfirm turns wt status of a main or locked row into the delete
// confirm, or the refusal for a locked worktree or a main checkout that
// still has linked worktrees. That refusal also shows them: the repo filter goes to the
// row's repo and the query is cleared (D102).
func (m *model) deleteConfirm(msg wtStatusMsg) {
	t := m.targetWT
	switch {
	case msg.err != nil:
		m.err = msg.err
	case t == nil:
	case msg.st.Main && msg.st.Linked > 0:
		m.showRepo(t)
		noun := "linked worktrees"
		if msg.st.Linked == 1 {
			noun = "linked worktree"
		}
		m.err = fmt.Errorf("%s still has %d %s: delete them first", t.Repo, msg.st.Linked, noun)
	case msg.st.Locked:
		reason := msg.st.LockReason
		if reason == "" {
			reason = "no reason given"
		}
		m.err = fmt.Errorf("refusing to delete %s: locked (%s)", t.Name, reason)
	default:
		m.openDeleteConfirm(t)
	}
}

// showRepo sets the repo filter to t's repo with an empty query, so the
// list shows that repo's rows only, and keeps the cursor on t.
func (m *model) showRepo(t *state.Worktree) {
	if m.hasRepos() {
		m.repo = t.Repo
	}
	m.query.SetValue("")
	m.resetList()
	for i, idx := range m.matches {
		if m.rows[idx].RowID() == t.Root {
			m.cur = i
			break
		}
	}
	m.listFollow()
	m.resetCards()
}
