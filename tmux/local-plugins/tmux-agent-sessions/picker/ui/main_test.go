package ui

import (
	"os"
	"testing"

	"agentpicker/inspect"
)

// Model tests never touch the filesystem or git through the async probes:
// they stay off unless a test sets model.async, and even then these
// stand-ins answer.
func TestMain(m *testing.M) {
	probeHeavy = func(root string) []string { return fakeHeavy[root] }
	readGit = func(root string) inspect.Git { return fakeGit[root] }
	os.Exit(m.Run())
}

var (
	fakeHeavy = map[string][]string{}
	fakeGit   = map[string]inspect.Git{}
)
