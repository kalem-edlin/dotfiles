package ui

import (
	"sort"
	"strings"
	"sync"

	"github.com/junegunn/fzf/src/algo"
	"github.com/junegunn/fzf/src/util"
)

var algoInit sync.Once

// matcher matches the query against session names with fzf's FuzzyMatchV2
// (D33). The whole query is one case-insensitive pattern: no extended
// syntax, no score sort.
type matcher struct {
	slab *util.Slab
}

func newMatcher() *matcher {
	// Without Init the bonus tables are zero and scores are wrong.
	algoInit.Do(func() { algo.Init("default") })
	return &matcher{slab: util.MakeSlab(100*1024, 2048)}
}

// match reports whether query matches name, and the matched rune indexes in
// ascending order. An empty query matches everything with no positions.
func (m *matcher) match(query, name string) (bool, []int) {
	if query == "" {
		return true, nil
	}
	pattern := []rune(strings.ToLower(query))
	chars := util.ToChars([]byte(name))
	res, pos := algo.FuzzyMatchV2(false, true, true, &chars, pattern, true, m.slab)
	if res.Start < 0 {
		return false, nil
	}
	var out []int
	if pos != nil {
		out = append(out, *pos...)
		sort.Ints(out) // fzf returns them descending
	}
	return true, out
}
