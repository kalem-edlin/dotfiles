package worktree

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
	"time"
)

// TestDiscover builds a Developer-like tree: a repo at depth 1 with linked
// worktrees beside it, in a hidden .eph dir, locked and missing; a repo at
// depth 2 with a slot directory that is both a depth-2 entry and a linked
// worktree; a second clone of the first repo; and things to skip.
func TestDiscover(t *testing.T) {
	f := newFixture(t)
	dev := f.mkdir("Developer")
	alpha := f.initRepo("Developer/alpha")
	f.git(alpha, "worktree", "add", "-q", "-b", "feat", f.path("Developer/alpha-feat"))
	f.git(alpha, "worktree", "add", "-q", "-b", "eph", f.path("Developer/.eph/alpha-x"))
	f.git(alpha, "worktree", "add", "-q", "-b", "kept", f.path("Developer/alpha-kept"))
	f.git(alpha, "worktree", "lock", "--reason", "heavy", f.path("Developer/alpha-kept"))
	f.git(alpha, "worktree", "add", "-q", "--detach", f.path("Developer/alpha-gone"))
	if err := os.RemoveAll(f.path("Developer/alpha-gone")); err != nil {
		t.Fatal(err)
	}
	beta := f.initRepo("Developer/org/beta")
	f.git(beta, "worktree", "add", "-q", "-b", "slot", f.path("Developer/org/beta-slot"))
	f.initRepo("Developer/org/alpha") // a second clone, its own repo
	f.initRepo("Developer/deep/a/b")  // depth 3: not a repo here
	f.mkdir("Developer/notes")
	f.write("Developer/readme.md", "x")
	f.initRepo("Developer/.hidden")

	old := time.Unix(1_700_000_000, 0)
	if err := os.Chtimes(filepath.Join(alpha, ".git", "HEAD"), old, old); err != nil {
		t.Fatal(err)
	}
	os.Chtimes(filepath.Join(alpha, ".git", "index"), old, old) // absent after an empty commit on some gits

	got := map[string]Entry{}
	var order []string
	for _, e := range Discover(dev) {
		if _, dup := got[e.Root]; dup {
			t.Errorf("duplicate root %s", e.Root)
		}
		got[e.Root] = e
		order = append(order, e.Root)
	}
	rel := func(p string) string { r, _ := filepath.Rel(dev, p); return r }
	var names []string
	for _, r := range order {
		names = append(names, rel(r))
	}
	sort.Strings(names)
	want := []string{".eph/alpha-x", "alpha", "alpha-feat", "alpha-gone", "alpha-kept", "org/alpha", "org/beta", "org/beta-slot"}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("roots %v\nwant  %v", names, want)
	}
	type facts struct {
		repo, branch     string
		main, lock, gone bool
		detached         bool
	}
	check := map[string]facts{
		"alpha":         {repo: "alpha", branch: "main", main: true},
		"alpha-feat":    {repo: "alpha", branch: "feat"},
		".eph/alpha-x":  {repo: "alpha", branch: "eph"},
		"alpha-kept":    {repo: "alpha", branch: "kept", lock: true},
		"alpha-gone":    {repo: "alpha", gone: true, detached: true},
		"org/beta":      {repo: "beta", branch: "main", main: true},
		"org/beta-slot": {repo: "beta", branch: "slot"},
		"org/alpha":     {repo: "alpha", branch: "main", main: true},
	}
	for r, w := range check {
		e := got[filepath.Join(dev, r)]
		if e.Repo != w.repo || e.Branch != w.branch || e.Main != w.main || e.Locked != w.lock || e.Missing != w.gone {
			t.Errorf("%s = %+v, want %+v", r, e, w)
		}
		if w.detached && (len(e.Head) != 7 || !e.Detached()) {
			t.Errorf("%s head %q", r, e.Head)
		}
		if e.Name != filepath.Base(r) {
			t.Errorf("%s name %q", r, e.Name)
		}
		if e.ActiveAt == 0 {
			t.Errorf("%s has no ActiveAt", r)
		}
	}
	// Two clones named alpha are two repos: different common dirs.
	if a, b := got[alpha], got[filepath.Join(dev, "org/alpha")]; a.CommonDir == b.CommonDir {
		t.Errorf("clones share %s", a.CommonDir)
	}
	if at := got[alpha].ActiveAt; at != old.Unix() {
		t.Errorf("main ActiveAt %d, want the HEAD mtime %d", at, old.Unix())
	}
	if Discover(f.path("nowhere")) != nil || Discover("") != nil {
		t.Error("a missing root lists nothing")
	}
}

// The root may be reached through a symlink: roots still dedupe, since
// git writes real paths.
func TestDiscoverSymlinkedRoot(t *testing.T) {
	f := newFixture(t)
	alpha := f.initRepo("real/alpha")
	f.git(alpha, "worktree", "add", "-q", "-b", "feat", f.path("real/alpha-feat"))
	if err := os.Symlink(f.path("real"), f.path("link")); err != nil {
		t.Fatal(err)
	}
	if n := len(Discover(f.path("link"))); n != 2 {
		t.Errorf("%d entries through a symlink, want 2", n)
	}
}

func TestDevRoot(t *testing.T) {
	t.Setenv(DevRootEnv, "/x/dev/")
	if got := DevRoot(); got != "/x/dev" {
		t.Errorf("env root %q", got)
	}
	t.Setenv(DevRootEnv, "")
	t.Setenv("HOME", "/home/u")
	if got := DevRoot(); got != "/home/u/Developer" {
		t.Errorf("default root %q", got)
	}
}

// BenchmarkDiscover scans 10 repos with 9 linked worktrees each plus 30
// plain directories.
func BenchmarkDiscover(b *testing.B) {
	f := newFixture(b)
	for r := range 10 {
		main := f.initRepo(fmt.Sprintf("dev/org/r%d", r))
		for w := range 9 {
			f.git(main, "worktree", "add", "-q", "-b", fmt.Sprintf("b%d", w), f.path(fmt.Sprintf("dev/org/r%d-%d", r, w)))
		}
	}
	for d := range 30 {
		f.mkdir(fmt.Sprintf("dev/plain%d/sub", d))
	}
	if n := len(Discover(f.path("dev"))); n != 100 {
		b.Fatalf("%d entries", n)
	}
	b.ReportAllocs()
	for b.Loop() {
		Discover(f.path("dev"))
	}
}
