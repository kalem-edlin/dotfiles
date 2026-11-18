package worktree

import (
	"os"
	"path/filepath"
	"strings"
)

// DevRootEnv overrides the discovery root, ~/Developer by default. Tests
// point it at a temp tree.
const DevRootEnv = "AGENT_SESSIONS_DEV_ROOT"

// DevRoot is the directory Discover scans: $AGENT_SESSIONS_DEV_ROOT, else
// ~/Developer.
func DevRoot() string {
	if d := os.Getenv(DevRootEnv); d != "" {
		return filepath.Clean(d)
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(h, "Developer")
}

// Entry is one worktree found by Discover.
type Entry struct {
	Info
	Name     string // the root's basename, which a session must be named after (V1)
	Main     bool   // the repo's main worktree, whose .git is a directory
	Locked   bool   // <admin>/locked exists (git worktree lock)
	Missing  bool   // the directory or its .git file is gone (git calls it prunable)
	ActiveAt int64  // newest mtime of the worktree's HEAD and index, epoch seconds
}

// Discover lists every worktree of every git repo under root, without
// spawning git (V5). A repo is any directory root/*/.git or root/*/*/.git
// (a .git directory or file; hidden names are skipped, as a shell glob
// would). Each repo's common dir then gives its main worktree and every
// linked worktree listed in <common>/worktrees/*/gitdir, wherever it lives
// (this is how .eph/* worktrees are found). Rows are deduped by root, so a
// slot directory that is both a depth-2 entry and a linked worktree shows
// once, and two clones of one project stay two repos. Directories that are
// not repos are skipped silently.
//
// root is passed through EvalSymlinks once, since git writes real paths
// into gitdir files and the scan must spell roots the same way.
func Discover(root string) []Entry {
	if root == "" {
		return nil
	}
	if real, err := filepath.EvalSymlinks(root); err == nil {
		root = real
	}
	d := &discoverer{r: NewResolver(), seen: map[string]bool{}, commons: map[string]bool{}}
	for _, c := range candidates(root) {
		info, ok := d.r.Resolve(c)
		if !ok || info.Root != c {
			continue
		}
		d.repo(info)
	}
	return d.out
}

type discoverer struct {
	r       *Resolver
	out     []Entry
	seen    map[string]bool // roots already listed
	commons map[string]bool // common dirs already enumerated
}

func (d *discoverer) add(e Entry) {
	if d.seen[e.Root] {
		return
	}
	d.seen[e.Root] = true
	e.Name = filepath.Base(e.Root)
	d.out = append(d.out, e)
}

// repo lists the worktrees of info's common dir once: the main checkout,
// then the linked worktrees in admin-dir order. A checkout whose common dir
// has no main checkout (a submodule, --separate-git-dir, a bare repo's
// linked worktree) is listed itself.
func (d *discoverer) repo(info Info) {
	c := info.CommonDir
	if !d.commons[c] {
		d.commons[c] = true
		if filepath.Base(c) == ".git" {
			main := filepath.Dir(c)
			if mi, ok := d.r.Resolve(main); ok && mi.Root == main {
				d.add(Entry{Info: mi, Main: true, ActiveAt: newestMtime(c)})
			}
		}
		d.linked(c)
	}
	if !d.seen[info.Root] {
		d.add(Entry{Info: info, ActiveAt: newestMtime(c)})
	}
}

// linked reads <common>/worktrees/*: gitdir names the worktree's .git file,
// locked marks a lock, and HEAD gives the branch even when the directory is
// gone.
func (d *discoverer) linked(common string) {
	admins, err := os.ReadDir(filepath.Join(common, "worktrees"))
	if err != nil {
		return
	}
	for _, a := range admins {
		if !a.IsDir() {
			continue
		}
		admin := filepath.Join(common, "worktrees", a.Name())
		b, ok := d.r.readSmall(filepath.Join(admin, "gitdir"))
		if !ok {
			continue
		}
		gd := strings.TrimSpace(string(firstLine(b)))
		if gd == "" {
			continue
		}
		if !filepath.IsAbs(gd) {
			gd = filepath.Join(admin, gd)
		}
		gd = filepath.Clean(gd)
		root := filepath.Dir(gd)
		info := Info{Root: root, CommonDir: common, Repo: repoName(root, common, true)}
		head, ok := d.r.readSmall(filepath.Join(admin, "HEAD"))
		if !ok || !parseHead(head, &info) {
			continue
		}
		e := Entry{Info: info, Locked: exists(filepath.Join(admin, "locked")), ActiveAt: newestMtime(admin)}
		if st, err := os.Stat(root); err != nil || !st.IsDir() || !exists(gd) {
			e.Missing = true
		}
		d.add(e)
	}
}

// candidates is every root/*/ and root/*/*/ directory holding a .git entry,
// in name order.
func candidates(root string) []string {
	var out []string
	for _, d1 := range subdirs(root) {
		if exists(filepath.Join(d1, ".git")) {
			out = append(out, d1)
		}
		for _, d2 := range subdirs(d1) {
			if exists(filepath.Join(d2, ".git")) {
				out = append(out, d2)
			}
		}
	}
	return out
}

// subdirs lists dir's non-hidden subdirectories, following symlinks.
func subdirs(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), ".") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		switch {
		case e.IsDir():
			out = append(out, p)
		case e.Type()&os.ModeSymlink != 0:
			if st, err := os.Stat(p); err == nil && st.IsDir() {
				out = append(out, p)
			}
		}
	}
	return out
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// newestMtime is the newer mtime of gitDir/HEAD and gitDir/index, 0 when
// neither exists. A commit, checkout or stage touches one of them.
func newestMtime(gitDir string) int64 {
	var at int64
	for _, f := range []string{"HEAD", "index"} {
		if st, err := os.Stat(filepath.Join(gitDir, f)); err == nil {
			at = max(at, st.ModTime().Unix())
		}
	}
	return at
}
