package ui

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

var update = flag.Bool("update", false, "rewrite golden files")

func golden(t *testing.T, name, got string) {
	t.Helper()
	path := filepath.Join("testdata", name+".golden")
	if *update {
		if err := os.MkdirAll("testdata", 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(got), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("%v (run go test ./ui/ -update)", err)
	}
	if string(want) != got {
		t.Errorf("%s differs from golden:\n--- got\n%s\n--- want\n%s", name, got, want)
	}
}

// plain strips ANSI and trailing spaces, and frames each line so widths
// are visible in the golden file.
func plain(lines []string) string {
	var b strings.Builder
	for _, l := range lines {
		b.WriteString(ansi.Strip(l))
		b.WriteString("|\n")
	}
	return b.String()
}

func checkWidths(t *testing.T, name string, lines []string, w int) {
	t.Helper()
	for i, l := range lines {
		if got := width(l); got != w {
			t.Errorf("%s line %d is %d columns, want %d: %q", name, i, got, w, ansi.Strip(l))
		}
	}
}

var widths = []int{80, 120, 200}

func TestGoldenSessionRows(t *testing.T) {
	snap := fixture()
	m := newMatcher()
	for _, w := range widths {
		var lines []string
		for i, s := range snap.Sessions {
			_, pos := m.match("roll", s.Name)
			lines = append(lines, renderRow(newSessionRow(s, pos), 11, w, i == 3, now))
		}
		lines = append(lines, renderEmptyRow(w))
		checkWidths(t, "rows", lines, w)
		golden(t, fmt.Sprintf("rows_%d", w), plain(lines))
		if w == 120 {
			golden(t, "rows_120_styled", strings.Join(lines, "\n")+"\n")
		}
	}
}

func TestGoldenCards(t *testing.T) {
	s := fixture().Sessions[3]
	cards := sessionCards(s)
	for _, w := range widths {
		lines := renderGrid(cards, 0, 0, w, 15, now)
		checkWidths(t, "cards", lines, w)
		golden(t, fmt.Sprintf("cards_%d", w), plain(lines))
		if w == 120 {
			golden(t, "cards_120_styled", strings.Join(lines, "\n")+"\n")
		}
	}
}

func TestGoldenInputLine(t *testing.T) {
	for _, w := range widths {
		m := newModel(&fakeActions{}, fixture(), nil)
		m.w = w
		rest := m.renderInput()
		m = send(t, m, "r", "o", "l", "l")
		query := m.renderInput()
		m = send(t, m, "ctrl+a")
		armed := m.renderInput()
		m = send(t, m, "R")
		prompt := m.renderInput()
		lines := []string{rest, query, armed, prompt}
		checkWidths(t, "input", lines, w)
		golden(t, fmt.Sprintf("input_%d", w), plain(lines))
		if w == 120 {
			golden(t, "input_120_styled", strings.Join(lines, "\n")+"\n")
		}
	}
}

// TestGoldenScreen renders the whole picker at 120x36 with the cursor on
// roll-web-funnel-changes.
func TestGoldenScreen(t *testing.T) {
	m := newModel(&fakeActions{}, fixture(), nil)
	m = resize(m, 120, 36)
	m = send(t, m, "ctrl+p")
	lines := strings.Split(m.render(), "\n")
	if len(lines) != 36 {
		t.Fatalf("screen has %d lines", len(lines))
	}
	checkWidths(t, "screen", lines, 120)
	golden(t, "screen_120x36", plain(lines))
}

// 13 rows leave 4 for the grid (6 list rows, 2 rules, the input line):
// less than one card row, so no grid.
func TestGridHiddenWhenShort(t *testing.T) {
	m := resize(newModel(&fakeActions{}, fixture(), nil), 80, 13)
	lines := strings.Split(m.render(), "\n")
	if len(lines) != 13 {
		t.Fatalf("%d lines", len(lines))
	}
	for _, l := range lines[:4] {
		if strings.TrimSpace(ansi.Strip(l)) != "" {
			t.Errorf("grid should be hidden, got %q", ansi.Strip(l))
		}
	}
}

func resize(m model, w, h int) model {
	nm, _ := m.Update(tea.WindowSizeMsg{Width: w, Height: h})
	return nm.(model)
}
