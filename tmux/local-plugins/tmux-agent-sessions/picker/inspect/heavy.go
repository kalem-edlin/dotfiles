// Package inspect reads per-worktree facts the list does not need for its
// first frame: heavy elements (stat only, after the first frame, V8) and
// the selected row's git state and ports (one git call when the cursor
// rests on a row, V7). See "Worktree list" in docs/tmux-agent-sessions.md.
package inspect

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
)

// Element is one heavy element: native build state that is expensive to
// recreate, shown as Symbol on every worktree row where Detect finds it.
type Element struct {
	Symbol string
	Name   string
	Detect func(root string) bool
}

// Heavy is the pattern table, one line per element (V8). node_modules is
// deliberately absent: nearly every worktree has it.
var Heavy = []Element{
	{"ios", "iOS native build (Pods or ios/build)", anyExists("apps/expo/ios/Pods", "ios/build")},
	{"lfs", "LFS models pulled (a Models file over 1 KB)", anyFileOver("packages/native-tools/ios/Models", 1024)},
}

// HeavySymbols is the symbol of every element present in root, in table
// order, nil for none.
func HeavySymbols(root string) []string {
	var out []string
	for _, e := range Heavy {
		if e.Detect(root) {
			out = append(out, e.Symbol)
		}
	}
	return out
}

// anyExists detects any of the relative paths.
func anyExists(rels ...string) func(string) bool {
	return func(root string) bool {
		for _, r := range rels {
			if _, err := os.Lstat(filepath.Join(root, r)); err == nil {
				return true
			}
		}
		return false
	}
}

var errFound = errors.New("found")

// anyFileOver detects a regular file under rel larger than size bytes. LFS
// pointer files are about 130 bytes, so a stat tells a pulled model from a
// pointer without reading it.
func anyFileOver(rel string, size int64) func(string) bool {
	return func(root string) bool {
		err := filepath.WalkDir(filepath.Join(root, rel), func(_ string, d fs.DirEntry, err error) error {
			if err != nil || !d.Type().IsRegular() {
				return nil
			}
			if info, err := d.Info(); err == nil && info.Size() > size {
				return errFound
			}
			return nil
		})
		return err == errFound
	}
}
