package tmuxio

import (
	"errors"
	"os"
	"reflect"
	"testing"
	"time"

	"agentpicker/state"
)

// The wt calls run the shim first in PATH; the harness asserts that.

func wtActions() *actions { return New(client).(*actions) }

func TestWorktreeNewArgv(t *testing.T) {
	reset(t)
	fixture(t, "out-wt-new", `{"ok":true,"path":"/r/app-b3","slug":"app-b3","branch":"b3","created_branch":true,"from":"origin/main","head":"abc1234","ports_block":1,"ports":{"NEXT_PORT":3100},"env_copied":[".env.local"],"env_rewritten":["NEXT_PORT"],"needs_install":true}`+"\n")
	a := wtActions()
	res, err := a.WorktreeNew("/r/app", "b3", "")
	expectOK(t, err)
	if res.Path != "/r/app-b3" || res.Branch != "b3" || !a.rediscover {
		t.Errorf("res=%+v rediscover=%v", res, a.rediscover)
	}
	expectCalls(t, wtLog, argv("new", "/r/app", "--branch", "b3", "--json"))
	expectCalls(t, tmuxLog) // wt never goes through tmux

	reset(t)
	fixture(t, "out-wt-new", `{"ok":true,"path":"/r/app-b4"}`)
	_, err = a.WorktreeNew("/r/app", "b4", "feat/x")
	expectOK(t, err)
	expectCalls(t, wtLog, argv("new", "/r/app", "--branch", "b4", "--from", "feat/x", "--json"))
}

func TestWorktreeStatusParse(t *testing.T) {
	reset(t)
	fixture(t, "out-wt-status", `{"ok":true,"path":"/r/x","main":false,"branch":"wt/x","head":"6c2a639dc","dirty":2,"untracked":1,"upstream":"origin/main","ahead":3,"behind":1,"merged":true,"locked":true,"lock_reason":"heavy","heavy":["ios","lfs"],"ports_block":16}`)
	a := wtActions()
	st, err := a.WorktreeStatus("/r/x")
	expectOK(t, err)
	want := state.WTStatus{Path: "/r/x", Branch: "wt/x", Head: "6c2a639dc", Dirty: 2, Untracked: 1,
		Upstream: "origin/main", Ahead: 3, Behind: 1, Merged: true, Locked: true, LockReason: "heavy",
		Heavy: []string{"ios", "lfs"}}
	if !reflect.DeepEqual(st, want) {
		t.Errorf("status\n got %+v\nwant %+v", st, want)
	}
	if a.rediscover {
		t.Error("status must not force a rescan")
	}
	expectCalls(t, wtLog, argv("status", "/r/x", "--json"))

	// Nulls (detached, no upstream, unlocked) read as zero values.
	reset(t)
	fixture(t, "out-wt-status", `{"ok":true,"path":"/r/y","main":true,"branch":null,"head":"1a2b3c4","dirty":0,"untracked":0,"upstream":null,"ahead":null,"behind":null,"merged":false,"locked":false,"lock_reason":null,"heavy":[],"ports_block":null}`)
	st, err = a.WorktreeStatus("/r/y")
	expectOK(t, err)
	if !st.Main || st.Branch != "" || st.Upstream != "" || st.Ahead != 0 || st.LockReason != "" {
		t.Errorf("nulls: %+v", st)
	}

	// A main checkout counts its linked worktrees (D102); null elsewhere.
	reset(t)
	fixture(t, "out-wt-status", `{"ok":true,"path":"/r/main","main":true,"branch":"main","head":"1a2b3c4","dirty":0,"untracked":0,"upstream":null,"ahead":null,"behind":null,"merged":false,"locked":false,"lock_reason":null,"heavy":[],"ports_block":null,"linked":3}`)
	if st, err = a.WorktreeStatus("/r/main"); err != nil || st.Linked != 3 {
		t.Errorf("linked: %+v %v", st, err)
	}
}

func TestWorktreeRepurposeArgv(t *testing.T) {
	reset(t)
	fixture(t, "out-wt-repurpose", `{"ok":true,"path":"/r/x","branch":"next","previous_branch":"wt/x","created_branch":true,"from":"origin/main","head":"abc","stashed":true,"stash":"f00ba12","stashed_changes":3,"ports_block":2,"needs_install":true,"needs_pods":false}`)
	a := wtActions()
	res, err := a.WorktreeRepurpose("/r/x", "next")
	expectOK(t, err)
	want := state.WTResult{Path: "/r/x", Branch: "next", PreviousBranch: "wt/x", Stashed: true, Stash: "f00ba12", StashedChanges: 3, NeedsInstall: true}
	if !reflect.DeepEqual(res, want) || !a.rediscover {
		t.Errorf("res=%+v rediscover=%v", res, a.rediscover)
	}
	expectCalls(t, wtLog, argv("repurpose", "/r/x", "--branch", "next", "--stash", "--json"))
}

func TestWorktreeRemoveArgv(t *testing.T) {
	reset(t)
	// A linked worktree goes to the Trash, never with --force (D105).
	fixture(t, "out-wt-rm", `{"ok":true,"removed":"/r/x","branch":"wt/x","trashed_to":"/h/.Trash/x","main":false}`)
	a := wtActions()
	res, err := a.WorktreeRemove("/r/x", false)
	expectOK(t, err)
	if res.Removed != "/r/x" || res.TrashedTo != "/h/.Trash/x" || res.Main || !a.rediscover {
		t.Errorf("res=%+v rediscover=%v", res, a.rediscover)
	}
	expectCalls(t, wtLog, argv("rm", "/r/x", "--json"))

	// A main checkout goes to the Trash; a missing worktree is pruned (D102).
	reset(t)
	fixture(t, "out-wt-rm", `{"ok":true,"removed":"/r/main","branch":"main","trashed_to":"/h/.Trash/main","main":true}`)
	res, err = a.WorktreeRemove("/r/main", false)
	expectOK(t, err)
	if want := (state.WTResult{Removed: "/r/main", Branch: "main", Main: true, TrashedTo: "/h/.Trash/main"}); !reflect.DeepEqual(res, want) {
		t.Errorf("main:\n got %+v\nwant %+v", res, want)
	}
	reset(t)
	fixture(t, "out-wt-rm", `{"ok":true,"pruned":"/r/gone","branch":"wt/gone"}`)
	res, err = a.WorktreeRemove("/r/gone", false)
	expectOK(t, err)
	if res.Pruned != "/r/gone" || res.Removed != "" || res.Main || !a.rediscover {
		t.Errorf("pruned: %+v", res)
	}
	expectCalls(t, wtLog, argv("rm", "/r/gone", "--json"))

	// A remote root the user confirmed losing (D11).
	reset(t)
	fixture(t, "out-wt-rm", `{"ok":true,"removed":"/r/x","branch":"wt/x","trashed_to":"/h/.Trash/x","main":false}`)
	_, err = a.WorktreeRemove("/r/x", true)
	expectOK(t, err)
	expectCalls(t, wtLog, argv("rm", "/r/x", "--discard-remote", "--json"))

	// The linked-worktrees refusal keeps wt's code and message.
	reset(t)
	fixture(t, "out-wt-rm", `{"ok":false,"code":5,"error":"main checkout has 2 linked worktrees: remove them first"}`)
	fixture(t, "exit-wt-rm", "5")
	_, err = a.WorktreeRemove("/r/main", false)
	var we *state.WTError
	if !errors.As(err, &we) || we.Code != state.WTRefused || err.Error() != "wt rm: main checkout has 2 linked worktrees: remove them first" {
		t.Errorf("linked refusal: %v", err)
	}
}

func TestWorktreeEnvRefreshArgv(t *testing.T) {
	reset(t)
	fixture(t, "out-wt-env-refresh", `{"ok":true,"main":"/r/main","source":"/r/main","pulled":true,"files":[".env.local",".env.production"],"refreshed":2,"missing":["/r/gone"],"worktrees":[{"path":"/r/x","ports_block":1,"copied":[".env.local",".env.production"],"rewritten":["NEXT_PORT"],"skipped":[]},{"path":"/r/y","ports_block":null,"copied":[".env.local"],"rewritten":[],"skipped":[".env.production"]}]}`)
	a := wtActions()
	res, err := a.WorktreeEnvRefresh("/r/x", false)
	expectOK(t, err)
	want := state.WTEnvResult{Main: "/r/main", Source: "/r/main", Pulled: true, Files: []string{".env.local", ".env.production"}, Refreshed: 2, Missing: []string{"/r/gone"},
		Worktrees: []state.WTEnvWorktree{
			{Path: "/r/x", Copied: []string{".env.local", ".env.production"}, Rewritten: []string{"NEXT_PORT"}, Skipped: []string{}},
			{Path: "/r/y", Copied: []string{".env.local"}, Rewritten: []string{}, Skipped: []string{".env.production"}},
		}}
	if !reflect.DeepEqual(res, want) || a.rediscover {
		t.Errorf("env-refresh:\n got %+v rediscover=%v\nwant %+v", res, a.rediscover, want)
	}
	expectCalls(t, wtLog, argv("env-refresh", "/r/x", "--json"))

	// --here makes the row's worktree the source.
	reset(t)
	fixture(t, "out-wt-env-refresh", `{"ok":true,"main":"/r/main","source":"/r/x","pulled":false,"files":[],"refreshed":0,"missing":[],"worktrees":[]}`)
	res, err = a.WorktreeEnvRefresh("/r/x", true)
	expectOK(t, err)
	if res.Source != "/r/x" || res.Pulled {
		t.Errorf("here: %+v", res)
	}
	expectCalls(t, wtLog, argv("env-refresh", "/r/x", "--here", "--json"))

	// A failed pull keeps wt's code and message.
	reset(t)
	fixture(t, "out-wt-env-refresh", `{"ok":false,"code":1,"error":"env pull failed in /r/main (exit 7): nope"}`)
	fixture(t, "exit-wt-env-refresh", "1")
	_, err = a.WorktreeEnvRefresh("/r/x", false)
	var we *state.WTError
	if !errors.As(err, &we) || we.Code != 1 || err.Error() != "wt env-refresh: env pull failed in /r/main (exit 7): nope" {
		t.Errorf("pull failure: %v", err)
	}
}

// A refusal carries wt's exit code and its JSON error; without JSON the
// first line of stderr, minus "wt: ".
func TestWTErrors(t *testing.T) {
	reset(t)
	fixture(t, "out-wt-rm", `{"ok":false,"code":4,"error":"locked: keep me: /r/x (use --force)"}`+"\n")
	fixture(t, "err-wt-rm", "wt: locked: keep me: /r/x (use --force)\n")
	fixture(t, "exit-wt-rm", "4")
	a := wtActions()
	_, err := a.WorktreeRemove("/r/x", false)
	var we *state.WTError
	if !errors.As(err, &we) || we.Code != state.WTLocked || we.Op != "rm" {
		t.Fatalf("err = %#v", err)
	}
	if err.Error() != "wt rm: locked: keep me: /r/x (use --force)" {
		t.Errorf("message %q", err)
	}
	if !a.rediscover {
		t.Error("a failed rm still rescans")
	}

	reset(t)
	fixture(t, "err-wt-new", "wt: target exists: /r/app-b3\nmore\n")
	fixture(t, "exit-wt-new", "5")
	_, err = a.WorktreeNew("/r/app", "b3", "")
	if !errors.As(err, &we) || we.Code != state.WTRefused || err.Error() != "wt new: target exists: /r/app-b3" {
		t.Errorf("stderr fallback: %v", err)
	}

	reset(t)
	fixture(t, "exit-wt-status", "1")
	_, err = a.WorktreeStatus("/r/x")
	if err == nil || err.Error() != "wt status: exit 1" {
		t.Errorf("silent failure: %v", err)
	}

	reset(t)
	fixture(t, "out-wt-status", "not json\n")
	_, err = a.WorktreeStatus("/r/x")
	if err == nil || err.Error() != "wt status: unreadable reply: not json" {
		t.Errorf("bad reply: %v", err)
	}
}

func TestWTTimeout(t *testing.T) {
	reset(t)
	defer func(d time.Duration) { wtTimeout = d }(wtTimeout)
	wtTimeout = 200 * time.Millisecond
	fixture(t, "sleep-wt", "")
	start := time.Now()
	_, err := wtActions().WorktreeStatus("/r/x")
	if err == nil || err.Error() != "wt status: timed out after 200ms" {
		t.Errorf("err = %v", err)
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Errorf("timeout took %s", d)
	}
}

func TestWTBinaryOverride(t *testing.T) {
	t.Setenv("AGENT_SESSIONS_WT", "/x/wt")
	if wtBinary() != "/x/wt" {
		t.Errorf("override: %q", wtBinary())
	}
	t.Setenv("AGENT_SESSIONS_WT", "")
	t.Setenv("PATH", "/nonexistent")
	if wtBinary() != homeDir+"/.local/bin/wt" {
		t.Errorf("fallback: %q", wtBinary())
	}
}

// The save starts detached and is not waited for; the picker never runs the
// real one in tests.
func TestSaveLayout(t *testing.T) {
	reset(t)
	expectOK(t, wtActions().SaveLayout())
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if b, _ := os.ReadFile(saveLog); len(b) > 0 {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	expectCalls(t, saveLog, argv("quiet"))

	t.Setenv("AGENT_SESSIONS_RESURRECT_SAVE", homeDir+"/missing.sh")
	expectErr(t, wtActions().SaveLayout(), "resurrect save not started")
}
