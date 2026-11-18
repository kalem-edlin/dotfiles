package inspect

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Git is a worktree's state for the preview (V7), plus its ports block.
type Git struct {
	Branch    string // branch.head: the branch, or "(detached)"
	Upstream  bool   // an upstream is configured, so Ahead and Behind mean something
	Ahead     int
	Behind    int
	Dirty     int    // tracked entries with staged or unstaged changes, conflicts included
	Untracked int    // untracked entries, as git status lists them (a new directory counts once)
	Added     int    // lines added against HEAD, staged and unstaged, text files only (D106)
	Deleted   int    // lines deleted against HEAD, the same way
	Err       string // git failed: the first line of its error
	Port      string // NEXT_PORT from <root>/.env.ports, "" without one
}

// gitPath is the git binary; tests may point it elsewhere.
var gitPath = "git"

// ReadGit runs `git status --porcelain=v2 --branch` in root (no optional
// locks, so it never blocks a concurrent git), then `git diff HEAD
// --numstat` for the line counts (D106), and reads .env.ports. It takes
// about 110 ms on a large worktree, so callers run it off the UI goroutine.
func ReadGit(root string) Git {
	g := Git{Port: readPort(filepath.Join(root, ".env.ports"))}
	cmd := exec.Command(gitPath, "--no-optional-locks", "-C", root, "status", "--porcelain=v2", "--branch")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(firstLine(stderr.String()))
		if msg == "" {
			msg = err.Error()
		}
		g.Err = msg
		return g
	}
	parseStatus(stdout.String(), &g)
	// Line counts are best effort: an unborn HEAD has nothing to diff.
	diff := exec.Command(gitPath, "--no-optional-locks", "-C", root, "diff", "HEAD", "--numstat")
	if out, err := diff.Output(); err == nil {
		parseNumstat(string(out), &g)
	}
	return g
}

// parseNumstat sums `git diff --numstat` lines (`added<tab>deleted<tab>path`);
// binary files show `-` and are skipped.
func parseNumstat(out string, g *Git) {
	for _, line := range strings.Split(out, "\n") {
		f := strings.SplitN(line, "\t", 3)
		if len(f) < 3 {
			continue
		}
		var a, d int
		if _, err := fmt.Sscanf(f[0]+" "+f[1], "%d %d", &a, &d); err != nil {
			continue
		}
		g.Added += a
		g.Deleted += d
	}
}

// parseStatus reads porcelain v2 output with --branch headers.
func parseStatus(out string, g *Git) {
	for _, line := range strings.Split(out, "\n") {
		switch {
		case strings.HasPrefix(line, "# branch.head "):
			g.Branch = strings.TrimPrefix(line, "# branch.head ")
		case strings.HasPrefix(line, "# branch.upstream "):
			g.Upstream = true
		case strings.HasPrefix(line, "# branch.ab "):
			fmt.Sscanf(strings.TrimPrefix(line, "# branch.ab "), "+%d -%d", &g.Ahead, &g.Behind)
		case strings.HasPrefix(line, "1 "), strings.HasPrefix(line, "2 "), strings.HasPrefix(line, "u "):
			g.Dirty++
		case strings.HasPrefix(line, "? "):
			g.Untracked++
		}
	}
}

// readPort is NEXT_PORT from an env file (`NEXT_PORT=3400`, optionally
// `export`ed or quoted), "" when the file or the key is absent.
func readPort(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		line = strings.TrimPrefix(line, "export ")
		k, v, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(k) != "NEXT_PORT" {
			continue
		}
		v = strings.TrimSpace(v)
		if i := strings.Index(v, " #"); i >= 0 {
			v = strings.TrimSpace(v[:i])
		}
		return strings.Trim(v, `"'`)
	}
	return ""
}

func firstLine(s string) string {
	l, _, _ := strings.Cut(strings.TrimSpace(s), "\n")
	return l
}
