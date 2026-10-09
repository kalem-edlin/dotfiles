package ui

import (
	"fmt"
	"sort"
)

// repoBadge is a repo's 2-letter code and the grey it sits on (D76).
type repoBadge struct {
	code   string
	fg, bg string
}

// badgeShades are the Mocha greys repo badges cycle through, darkest
// first, with the text colour that reads on each. Surface1 is left out:
// it is almost the selected row background.
var badgeShades = []struct{ bg, fg string }{
	{cSurface2, cText},
	{cOverlay0, cText},
	{cOverlay1, cCrust},
	{cOverlay2, cCrust},
	{cSubtext0, cCrust},
	{cSubtext1, cCrust},
}

// assignRepoBadges gives each distinct repo name a unique 2-character code
// and a shade (D76). Names claim in sorted order, so the result depends on
// the set of names only. Codes come from the lowercased ASCII letters and
// digits: the first two, then the initials of the first two segments, then
// the first with each later one, then the first with 1-9, then 00-99. The
// i-th name in sorted order gets shade i mod 6.
func assignRepoBadges(names []string) map[string]repoBadge {
	sorted := append([]string(nil), names...)
	sort.Strings(sorted)
	out := make(map[string]repoBadge, len(sorted))
	taken := map[string]bool{}
	i := 0
	for _, name := range sorted {
		if _, dup := out[name]; dup {
			continue
		}
		cands := badgeCandidates(name)
		code := cands[0]
		for _, c := range cands {
			if !taken[c] {
				code = c
				break
			}
		}
		taken[code] = true
		sh := badgeShades[i%len(badgeShades)]
		out[name] = repoBadge{code: code, fg: sh.fg, bg: sh.bg}
		i++
	}
	return out
}

// badgeCandidates lists a name's possible codes in order of preference.
func badgeCandidates(name string) []string {
	var alnum []byte
	var segs [][]byte
	inSeg := false
	for i := 0; i < len(name); i++ {
		c := name[i]
		if 'A' <= c && c <= 'Z' {
			c += 'a' - 'A'
		}
		if ('a' <= c && c <= 'z') || ('0' <= c && c <= '9') {
			alnum = append(alnum, c)
			if !inSeg {
				segs = append(segs, nil)
			}
			segs[len(segs)-1] = append(segs[len(segs)-1], c)
			inSeg = true
		} else {
			inSeg = false
		}
	}
	var out []string
	if len(alnum) > 0 {
		first := alnum[0]
		if len(alnum) >= 2 {
			out = append(out, string(alnum[:2]))
		}
		if len(segs) >= 2 {
			out = append(out, string([]byte{segs[0][0], segs[1][0]}))
		}
		for _, c := range alnum[1:] {
			out = append(out, string([]byte{first, c}))
		}
		for d := byte('1'); d <= '9'; d++ {
			out = append(out, string([]byte{first, d}))
		}
	}
	for n := 0; n < 100; n++ {
		out = append(out, fmt.Sprintf("%02d", n))
	}
	return out
}
