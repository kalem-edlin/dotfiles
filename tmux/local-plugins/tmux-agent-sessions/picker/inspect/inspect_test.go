package inspect

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func write(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(strings.Repeat("x", size)), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestHeavySymbols(t *testing.T) {
	base := t.TempDir()
	root := func(name string) string { return filepath.Join(base, name) }
	os.MkdirAll(filepath.Join(root("pods"), "apps/expo/ios/Pods"), 0o755)
	os.MkdirAll(filepath.Join(root("build"), "ios/build"), 0o755)
	write(t, filepath.Join(root("models"), "packages/native-tools/ios/Models/a/model.bin"), 2048)
	write(t, filepath.Join(root("pointers"), "packages/native-tools/ios/Models/model.bin"), 130)
	write(t, filepath.Join(root("pointers"), "packages/native-tools/ios/Models/exact.bin"), 1024)
	os.MkdirAll(filepath.Join(root("both"), "apps/expo/ios/Pods"), 0o755)
	write(t, filepath.Join(root("both"), "packages/native-tools/ios/Models/m.bin"), 4096)
	os.MkdirAll(filepath.Join(root("nm"), "node_modules/x"), 0o755)

	for name, want := range map[string][]string{
		"pods": {"ios"}, "build": {"ios"}, "models": {"lfs"}, "pointers": nil,
		"both": {"ios", "lfs"}, "nm": nil, "absent": nil,
	} {
		if got := HeavySymbols(root(name)); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v, want %v", name, got, want)
		}
	}
}

func TestParseStatus(t *testing.T) {
	out := strings.Join([]string{
		"# branch.oid 0123456789abcdef",
		"# branch.head exp/roll",
		"# branch.upstream origin/exp/roll",
		"# branch.ab +2 -5",
		"1 .M N... 100644 100644 100644 a b src/a.ts",
		"1 M. N... 100644 100644 100644 a b src/b.ts",
		"2 R. N... 100644 100644 100644 a b R100 new.ts\told.ts",
		"u UU N... 100644 100644 100644 100644 a b c conflict.ts",
		"? notes/",
		"? scratch.txt",
		"! ignored",
		"",
	}, "\n")
	var g Git
	parseStatus(out, &g)
	want := Git{Branch: "exp/roll", Upstream: true, Ahead: 2, Behind: 5, Dirty: 4, Untracked: 2}
	if g != want {
		t.Errorf("got %+v\nwant %+v", g, want)
	}
	g = Git{}
	parseStatus("# branch.oid abc\n# branch.head main\n", &g)
	if g != (Git{Branch: "main"}) {
		t.Errorf("clean, no upstream: %+v", g)
	}
}

func TestParseNumstat(t *testing.T) {
	var g Git
	parseNumstat("3\t1\ta.go\n-\t-\timg.png\n0\t7\tb.go\n\n", &g)
	if g.Added != 3 || g.Deleted != 8 {
		t.Errorf("got +%d -%d, want +3 -8", g.Added, g.Deleted)
	}
}

func TestReadPort(t *testing.T) {
	dir := t.TempDir()
	for content, want := range map[string]string{
		"NEXT_PORT=3400\n":                       "3400",
		"# ports\nAPI_PORT=4000\nNEXT_PORT=3410": "3410",
		"export NEXT_PORT=\"3420\" # slot 2\n":   "3420",
		"API_PORT=4000\n":                        "",
	} {
		p := filepath.Join(dir, ".env.ports")
		os.WriteFile(p, []byte(content), 0o644)
		if got := readPort(p); got != want {
			t.Errorf("%q: %q, want %q", content, got, want)
		}
	}
	if got := readPort(filepath.Join(dir, "absent")); got != "" {
		t.Errorf("absent file: %q", got)
	}
}

// ReadGit against a real repo: a dirty file, an untracked one, no
// upstream, and the ports file (itself untracked).
func TestReadGit(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	dir := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(), "GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
			"GIT_AUTHOR_NAME=f", "GIT_AUTHOR_EMAIL=f@x.invalid", "GIT_COMMITTER_NAME=f", "GIT_COMMITTER_EMAIL=f@x.invalid")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q", "-b", "main")
	write(t, filepath.Join(dir, "a.txt"), 1)
	run("add", "a.txt")
	run("commit", "-q", "-m", "init")
	write(t, filepath.Join(dir, "a.txt"), 2)
	write(t, filepath.Join(dir, "new.txt"), 1)
	os.WriteFile(filepath.Join(dir, ".env.ports"), []byte("NEXT_PORT=3400\n"), 0o644)
	g := ReadGit(dir)
	want := Git{Branch: "main", Dirty: 1, Untracked: 2, Added: 1, Deleted: 1, Port: "3400"}
	if g != want {
		t.Errorf("got %+v, want %+v", g, want)
	}
	if g := ReadGit(filepath.Join(dir, "absent")); g.Err == "" {
		t.Errorf("missing dir: %+v", g)
	}
}
