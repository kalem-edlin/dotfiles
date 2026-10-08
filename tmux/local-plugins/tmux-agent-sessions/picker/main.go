// agent-picker is the prefix o session picker. The binding passes the
// invoking client's name as the only argument.
package main

import (
	"fmt"
	"os"

	"agentpicker/tmuxio"
	"agentpicker/ui"
)

func main() {
	client := ""
	if len(os.Args) > 1 {
		client = os.Args[1]
	}
	if err := ui.Run(tmuxio.New(client)); err != nil {
		// The popup closes on exit, so a failure before the first frame
		// would vanish unseen. Keep it on screen until enter is pressed.
		fmt.Fprintln(os.Stderr, "agent-picker:", err)
		fmt.Fprint(os.Stderr, "press enter to close")
		var b [1]byte
		os.Stdin.Read(b[:])
	}
	// run-shell opens view mode on a non-zero exit, which traps the client
	// until q (see the binding), so the picker always exits 0.
	os.Exit(0)
}
