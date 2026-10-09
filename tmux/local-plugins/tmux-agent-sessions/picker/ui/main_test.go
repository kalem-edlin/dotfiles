package ui

import (
	"os"
	"testing"
)

// Most tests drive session mode from a fresh model, so they open there;
// TestOpenMode covers the real default.
func TestMain(m *testing.M) {
	openMode = modeSessions
	os.Exit(m.Run())
}
