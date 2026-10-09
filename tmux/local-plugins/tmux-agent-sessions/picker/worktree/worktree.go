// Package worktree resolves a directory to the git worktree that holds it,
// by reading the filesystem only. It never spawns git: the picker resolves
// every pane directory on every load, so the walk must stay well under a
// millisecond for a typical session list.
//
// The walk goes up from a directory to the first .git entry:
//   - a .git directory is a main worktree; its common dir is that directory;
//   - a .git file holds "gitdir: <path>"; the worktree's HEAD lives in that
//     gitdir and its common dir is named by <gitdir>/commondir, or is the
//     gitdir itself when commondir is absent (submodules, --separate-git-dir).
//
// Paths are cleaned but never passed through EvalSymlinks (cost). Git writes
// gitdir paths in .git files as real paths, so a linked worktree's CommonDir
// can be the symlink-free spelling of a main checkout's CommonDir when the
// checkout was reached through a symlink.
package worktree

import (
	"bytes"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Info describes the worktree that holds a directory.
type Info struct {
	Root      string // worktree root: the directory holding the .git entry
	CommonDir string // absolute, cleaned git common dir
	Repo      string // source repo directory name
	Branch    string // e.g. "exp/roll-hiring"; empty when detached
	Head      string // 7-char commit id when detached, else empty
}

// Detached reports whether HEAD points at a commit rather than a ref.
func (i Info) Detached() bool { return i.Branch == "" }

type result struct {
	info Info
	ok   bool
}

// Resolver caches results for the lifetime of one picker load. It is not
// safe for concurrent use.
type Resolver struct {
	// dirs maps every directory a walk has passed through (input dirs,
	// their ancestors up to the worktree root, and dirs found in no repo)
	// to its result, so a sibling of a resolved subdirectory stops at the
	// first shared ancestor.
	dirs map[string]result
	buf  []byte // scratch for small file reads; contents are copied out
}

// NewResolver returns an empty resolver.
func NewResolver() *Resolver {
	return &Resolver{dirs: make(map[string]result, 64), buf: make([]byte, 4096)}
}

// Resolve returns the worktree holding dir. It returns false when dir is in
// no repository, does not exist, or its .git entry or HEAD is unreadable or
// malformed.
func (r *Resolver) Resolve(dir string) (Info, bool) {
	if dir == "" {
		return Info{}, false
	}
	if !filepath.IsAbs(dir) {
		abs, err := filepath.Abs(dir)
		if err != nil {
			return Info{}, false
		}
		dir = abs
	} else {
		dir = filepath.Clean(dir)
	}
	if res, hit := r.dirs[dir]; hit {
		return res.info, res.ok
	}
	// A missing directory would otherwise resolve to whatever repo holds
	// its parent; git refuses it, and so do we.
	if st, err := os.Stat(dir); err != nil || !st.IsDir() {
		r.dirs[dir] = result{}
		return Info{}, false
	}

	var walked []string
	res := result{}
	d := dir
	for {
		if hit, ok := r.dirs[d]; ok {
			res = hit
			break
		}
		walked = append(walked, d)
		if found, res2 := r.probe(d); found {
			res = res2
			break
		}
		parent := filepath.Dir(d)
		if parent == d {
			break
		}
		d = parent
	}
	for _, w := range walked {
		r.dirs[w] = res
	}
	return res.info, res.ok
}

// probe checks d for a .git entry. found is true when the entry exists,
// whether or not it turned out to be valid; the walk stops there either way.
func (r *Resolver) probe(d string) (found bool, res result) {
	gitPath := filepath.Join(d, ".git")
	st, err := os.Stat(gitPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false, result{}
		}
		// Present but unreadable (permissions, ENOTDIR races): stop here.
		return true, result{}
	}
	if st.IsDir() {
		info, ok := r.fromGitDir(d, gitPath, gitPath, false)
		return true, result{info, ok}
	}
	info, ok := r.fromGitFile(d, gitPath)
	return true, result{info, ok}
}

func (r *Resolver) fromGitFile(root, gitFile string) (Info, bool) {
	b, ok := r.readSmall(gitFile)
	if !ok {
		return Info{}, false
	}
	line := firstLine(b)
	const prefix = "gitdir:"
	if !bytes.HasPrefix(line, []byte(prefix)) {
		return Info{}, false
	}
	gd := string(bytes.TrimSpace(line[len(prefix):]))
	if gd == "" {
		return Info{}, false
	}
	if !filepath.IsAbs(gd) {
		gd = filepath.Join(root, gd)
	} else {
		gd = filepath.Clean(gd)
	}

	common := gd
	viaCommondir := false
	if c, ok := r.readSmall(filepath.Join(gd, "commondir")); ok {
		cd := string(bytes.TrimSpace(firstLine(c)))
		if cd != "" {
			if !filepath.IsAbs(cd) {
				cd = filepath.Join(gd, cd)
			} else {
				cd = filepath.Clean(cd)
			}
			common = cd
			viaCommondir = true
		}
	}
	return r.fromGitDir(root, gd, common, viaCommondir)
}

// fromGitDir reads HEAD from gitDir and assembles the Info.
func (r *Resolver) fromGitDir(root, gitDir, common string, viaCommondir bool) (Info, bool) {
	head, ok := r.readSmall(filepath.Join(gitDir, "HEAD"))
	if !ok {
		return Info{}, false
	}
	info := Info{Root: root, CommonDir: common, Repo: repoName(root, common, viaCommondir)}
	h := bytes.TrimSpace(firstLine(head))
	if ref, isRef := bytes.CutPrefix(h, []byte("ref:")); isRef {
		ref = bytes.TrimSpace(ref)
		if len(ref) == 0 {
			return Info{}, false
		}
		s := string(ref)
		if b, ok := strings.CutPrefix(s, "refs/heads/"); ok {
			info.Branch = b
		} else {
			info.Branch = strings.TrimPrefix(s, "refs/")
		}
		return info, true
	}
	if len(h) < 7 || !isHex(h) {
		return Info{}, false
	}
	info.Head = string(h[:7])
	return info, true
}

// repoName returns the source repo's local directory name.
//   - <main>/.git -> basename(<main>)
//   - <name>.git (bare) -> <name>
//   - any other common dir reached through a commondir file (a bare repo
//     without the .git suffix, or a submodule's linked worktree) -> its
//     basename
//   - otherwise (submodule checkout, --separate-git-dir) -> basename(root)
func repoName(root, common string, viaCommondir bool) string {
	base := filepath.Base(common)
	switch {
	case base == ".git":
		return filepath.Base(filepath.Dir(common))
	case strings.HasSuffix(base, ".git") && len(base) > len(".git"):
		return strings.TrimSuffix(base, ".git")
	case viaCommondir:
		return base
	default:
		return filepath.Base(root)
	}
}

// readSmall reads up to 4 KiB of a file with open+read+close (no fstat)
// into the resolver's scratch buffer, valid until the next call. .git files,
// commondir and HEAD are all one short line.
func (r *Resolver) readSmall(path string) ([]byte, bool) {
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	n, err := io.ReadFull(f, r.buf)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil, false
	}
	return r.buf[:n], true
}

func firstLine(b []byte) []byte {
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		return b[:i]
	}
	return b
}

func isHex(b []byte) bool {
	for _, c := range b {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') {
			return false
		}
	}
	return true
}
