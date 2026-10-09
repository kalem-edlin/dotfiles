package worktree

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitEnv isolates fixture git runs from the user's config.
func gitEnv(home string) []string {
	env := []string{}
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "GIT_") || strings.HasPrefix(kv, "HOME=") || strings.HasPrefix(kv, "XDG_CONFIG_HOME=") {
			continue
		}
		env = append(env, kv)
	}
	return append(env,
		"HOME="+home,
		"XDG_CONFIG_HOME="+filepath.Join(home, ".config"),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=Fixture",
		"GIT_AUTHOR_EMAIL=fixture@example.invalid",
		"GIT_COMMITTER_NAME=Fixture",
		"GIT_COMMITTER_EMAIL=fixture@example.invalid",
		"GIT_TERMINAL_PROMPT=0",
	)
}

type fixture struct {
	tb   testing.TB
	base string
}

func newFixture(tb testing.TB) *fixture {
	tb.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		tb.Skip("git not installed")
	}
	// Git writes real paths into .git files; resolve the temp dir's symlinks
	// (/var -> /private/var on macOS) so expectations use one spelling.
	base, err := filepath.EvalSymlinks(tb.TempDir())
	if err != nil {
		tb.Fatal(err)
	}
	return &fixture{tb: tb, base: base}
}

func (f *fixture) path(rel string) string { return filepath.Join(f.base, rel) }

func (f *fixture) git(dir string, args ...string) string {
	f.tb.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = gitEnv(f.path(".home"))
	out, err := cmd.CombinedOutput()
	if err != nil {
		f.tb.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func (f *fixture) mkdir(rel string) string {
	f.tb.Helper()
	p := f.path(rel)
	if err := os.MkdirAll(p, 0o755); err != nil {
		f.tb.Fatal(err)
	}
	return p
}

func (f *fixture) write(rel, content string) {
	f.tb.Helper()
	p := f.path(rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.tb.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		f.tb.Fatal(err)
	}
}

// initRepo creates a main checkout on branch main with one commit.
func (f *fixture) initRepo(rel string) string {
	f.tb.Helper()
	p := f.mkdir(rel)
	f.git(p, "init", "-q", "-b", "main")
	f.git(p, "commit", "-q", "--allow-empty", "-m", "init")
	return p
}

func TestResolve(t *testing.T) {
	f := newFixture(t)
	main := f.initRepo("proj")
	f.mkdir("proj/apps/expo")
	head := f.git(main, "rev-parse", "HEAD")
	common := filepath.Join(main, ".git")

	f.git(main, "worktree", "add", "-q", "-b", "feature", f.path("wt-linked"))
	f.mkdir("wt-linked/src/deep")
	f.git(main, "worktree", "add", "-q", "-b", "exp/roll-hiring", f.path("active/roll-hiring"))
	f.git(main, "worktree", "add", "-q", "--detach", f.path("wt-detached"))
	f.git(main, "worktree", "add", "-q", "--relative-paths", "-b", "rel", f.path("wt-relative"))
	gitFile, err := os.ReadFile(f.path("wt-relative/.git"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.HasPrefix(strings.TrimPrefix(string(gitFile), "gitdir: "), "/") {
		t.Fatalf("expected relative gitdir, got %q", gitFile)
	}

	// Absolute gitdir written by hand (independent of git's default).
	f.git(main, "worktree", "add", "-q", "-b", "abs", f.path("wt-absolute"))
	f.write("wt-absolute/.git", "gitdir: "+filepath.Join(common, "worktrees", "wt-absolute")+"\n")

	// Linked worktree whose commondir file is gone: the gitdir is the common dir.
	f.git(main, "worktree", "add", "-q", "-b", "nocommon", f.path("wt-nocommon"))
	nocommonGitdir := filepath.Join(common, "worktrees", "wt-nocommon")
	if err := os.Remove(filepath.Join(nocommonGitdir, "commondir")); err != nil {
		t.Fatal(err)
	}

	// Bare repos with linked worktrees, with and without the .git suffix.
	f.git(f.base, "clone", "-q", "--bare", main, f.path("bare/svc.git"))
	f.git(f.path("bare/svc.git"), "worktree", "add", "-q", "-b", "bare-feat", f.path("bare/svc-wt"))
	f.mkdir("bare/svc-wt/pkg")
	f.git(f.base, "clone", "-q", "--bare", main, f.path("bare/plain"))
	f.git(f.path("bare/plain"), "worktree", "add", "-q", "-b", "plain-feat", f.path("bare/plain-wt"))

	// Non-ref, non-branch HEAD (e.g. a remote-tracking ref).
	f.git(main, "worktree", "add", "-q", "-b", "other", f.path("wt-otherref"))
	if err := os.WriteFile(filepath.Join(common, "worktrees", "wt-otherref", "HEAD"), []byte("ref: refs/remotes/origin/main\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Malformed .git files.
	f.mkdir("bad-garbage/sub")
	f.write("bad-garbage/.git", "this is not a gitdir line\n")
	f.mkdir("bad-empty")
	f.write("bad-empty/.git", "gitdir: \n")
	f.mkdir("bad-missing")
	f.write("bad-missing/.git", "gitdir: /nonexistent/worktrees/gone\n")
	f.mkdir("bad-head/.git")
	f.write("bad-head/.git/HEAD", "zzzz\n")

	f.mkdir("plain/sub")

	tests := []struct {
		name string
		dir  string
		want Info
		ok   bool
	}{
		{"main checkout", main, Info{Root: main, CommonDir: common, Repo: "proj", Branch: "main"}, true},
		{"main subdir", f.path("proj/apps/expo"), Info{Root: main, CommonDir: common, Repo: "proj", Branch: "main"}, true},
		{"main trailing slash", main + "/", Info{Root: main, CommonDir: common, Repo: "proj", Branch: "main"}, true},
		{"linked worktree", f.path("wt-linked"), Info{Root: f.path("wt-linked"), CommonDir: common, Repo: "proj", Branch: "feature"}, true},
		{"linked subdir", f.path("wt-linked/src/deep"), Info{Root: f.path("wt-linked"), CommonDir: common, Repo: "proj", Branch: "feature"}, true},
		{"branch with slashes", f.path("active/roll-hiring"), Info{Root: f.path("active/roll-hiring"), CommonDir: common, Repo: "proj", Branch: "exp/roll-hiring"}, true},
		{"detached HEAD", f.path("wt-detached"), Info{Root: f.path("wt-detached"), CommonDir: common, Repo: "proj", Head: head[:7]}, true},
		{"relative gitdir", f.path("wt-relative"), Info{Root: f.path("wt-relative"), CommonDir: common, Repo: "proj", Branch: "rel"}, true},
		{"absolute gitdir", f.path("wt-absolute"), Info{Root: f.path("wt-absolute"), CommonDir: common, Repo: "proj", Branch: "abs"}, true},
		{"missing commondir", f.path("wt-nocommon"), Info{Root: f.path("wt-nocommon"), CommonDir: nocommonGitdir, Repo: "wt-nocommon", Branch: "nocommon"}, true},
		{"other ref", f.path("wt-otherref"), Info{Root: f.path("wt-otherref"), CommonDir: common, Repo: "proj", Branch: "remotes/origin/main"}, true},
		{"bare linked worktree", f.path("bare/svc-wt"), Info{Root: f.path("bare/svc-wt"), CommonDir: f.path("bare/svc.git"), Repo: "svc", Branch: "bare-feat"}, true},
		{"bare linked subdir", f.path("bare/svc-wt/pkg"), Info{Root: f.path("bare/svc-wt"), CommonDir: f.path("bare/svc.git"), Repo: "svc", Branch: "bare-feat"}, true},
		{"bare without suffix", f.path("bare/plain-wt"), Info{Root: f.path("bare/plain-wt"), CommonDir: f.path("bare/plain"), Repo: "plain", Branch: "plain-feat"}, true},
		{"non-repo dir", f.path("plain"), Info{}, false},
		{"non-repo subdir", f.path("plain/sub"), Info{}, false},
		{"nonexistent dir", f.path("proj/nope"), Info{}, false},
		{"empty input", "", Info{}, false},
		{"malformed .git file", f.path("bad-garbage"), Info{}, false},
		{"malformed .git file subdir", f.path("bad-garbage/sub"), Info{}, false},
		{"empty gitdir", f.path("bad-empty"), Info{}, false},
		{"gitdir points nowhere", f.path("bad-missing"), Info{}, false},
		{"malformed HEAD", f.path("bad-head"), Info{}, false},
	}

	// Each case against a fresh resolver, then all cases against one shared
	// resolver in order and in reverse, so cache paths agree with cold paths.
	check := func(t *testing.T, r *Resolver, dir string, want Info, wantOK bool) {
		t.Helper()
		got, ok := r.Resolve(dir)
		if ok != wantOK || got != want {
			t.Errorf("Resolve(%q) = %+v, %v; want %+v, %v", dir, got, ok, want, wantOK)
		}
		if ok && got.Detached() != (want.Branch == "") {
			t.Errorf("Detached() = %v for %+v", got.Detached(), got)
		}
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) { check(t, NewResolver(), tc.dir, tc.want, tc.ok) })
	}
	t.Run("shared resolver", func(t *testing.T) {
		r := NewResolver()
		for _, tc := range tests {
			check(t, r, tc.dir, tc.want, tc.ok)
		}
		for i := len(tests) - 1; i >= 0; i-- {
			check(t, r, tests[i].dir, tests[i].want, tests[i].ok)
		}
	})
}

func TestResolverCache(t *testing.T) {
	f := newFixture(t)
	main := f.initRepo("proj")
	f.mkdir("proj/a/x")
	f.mkdir("proj/a/y")
	f.mkdir("plain/sub")

	r := NewResolver()
	first, ok := r.Resolve(f.path("proj/a/x"))
	if !ok || first.Root != main {
		t.Fatalf("Resolve = %+v, %v", first, ok)
	}
	neg, negOK := r.Resolve(f.path("plain/sub"))
	if negOK {
		t.Fatalf("non-repo resolved: %+v", neg)
	}

	// Break the repo on disk: cached results must not change within a load.
	if err := os.Rename(filepath.Join(main, ".git"), filepath.Join(main, ".git-moved")); err != nil {
		t.Fatal(err)
	}
	again, ok := r.Resolve(f.path("proj/a/x"))
	if !ok || again != first {
		t.Errorf("cached Resolve = %+v, %v; want %+v", again, ok, first)
	}
	// A sibling subdir stops at the cached shared ancestor proj/a.
	sib, ok := r.Resolve(f.path("proj/a/y"))
	if !ok || sib != first {
		t.Errorf("sibling Resolve = %+v, %v; want %+v", sib, ok, first)
	}
	if _, ok := r.Resolve(f.path("plain/sub")); ok {
		t.Error("negative result not cached")
	}

	// A fresh resolver sees the change.
	if _, ok := NewResolver().Resolve(f.path("proj/a/x")); ok {
		t.Error("fresh resolver resolved a dir whose .git was moved")
	}
}

// benchDirs builds ~10 worktrees with subdirectories plus non-repo dirs and
// returns 100 directories to resolve.
func benchDirs(b *testing.B) []string {
	f := newFixture(b)
	main := f.initRepo("repo-1")
	roots := []string{main}
	for i := 2; i <= 10; i++ {
		p := f.path(fmt.Sprintf("repo-%d", i))
		if i%3 == 0 {
			f.git(main, "worktree", "add", "-q", "--detach", p)
		} else {
			f.git(main, "worktree", "add", "-q", "-b", fmt.Sprintf("exp/b%d", i), p)
		}
		roots = append(roots, p)
	}
	var dirs []string
	for _, root := range roots {
		dirs = append(dirs, root)
		for j := 0; j < 8; j++ {
			d := filepath.Join(root, "apps", fmt.Sprintf("app%d", j%4), "src", fmt.Sprintf("m%d", j))
			if err := os.MkdirAll(d, 0o755); err != nil {
				b.Fatal(err)
			}
			dirs = append(dirs, d)
		}
	}
	for i := 0; len(dirs) < 100; i++ {
		dirs = append(dirs, f.mkdir(fmt.Sprintf("plain/p%d/sub", i)))
	}
	return dirs
}

func BenchmarkResolve100(b *testing.B) {
	dirs := benchDirs(b)
	if len(dirs) != 100 {
		b.Fatalf("got %d dirs", len(dirs))
	}
	b.ReportAllocs()
	for b.Loop() {
		r := NewResolver()
		for _, d := range dirs {
			r.Resolve(d)
		}
	}
}
