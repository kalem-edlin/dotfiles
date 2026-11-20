#!/usr/bin/python3
"""Cases for libexec/rw-paste-shim (C4 in docs/tasks/drop-to-remote-paste.md).

Run by test_paste_shim.sh, which builds the sandbox and the fakes (fake
`tmux` on PATH, fake child, fake scp, endpoint record) and exports SANDBOX,
WS, FAKE_*. Two layers:
  - unit: the pure parts loaded with runpy (parse_paths, ghostty_escape,
    PasteCapture);
  - end to end: the real binary with a pty as its terminal (the test holds
    the master), a fake tmux client as its child that records every byte.
Every wait is bounded; a global alarm stops a hung run.
"""

import fcntl
import os
import runpy
import select
import signal
import struct
import subprocess
import sys
import termios
import threading
import time

SHIM = sys.argv[1]
SANDBOX = os.environ["SANDBOX"]
WS = os.environ["WS"]
WORKER_HOME = os.environ["FAKE_WORKER_HOME"]
S = runpy.run_path(SHIM, run_name="rw_paste_shim")
START, END = S["START"], S["END"]
esc = S["ghostty_escape"]

passed = failed = 0


def ok(desc, cond, detail=None):
    global passed, failed
    if cond:
        passed += 1
        print("ok   " + desc, flush=True)
    else:
        failed += 1
        print("FAIL " + desc, flush=True)
        if detail is not None:
            print("     " + str(detail)[:600], flush=True)


def eq(desc, got, want):
    ok(desc, got == want, "got:  %r\n     want: %r" % (got, want))


def on_alarm(signum, frame):
    print("FAIL driver timed out (global alarm)", flush=True)
    os._exit(3)


signal.signal(signal.SIGALRM, on_alarm)
signal.alarm(150)

# ---------------------------------------------------------------------------
# Unit: classifier and capture state machine
# ---------------------------------------------------------------------------

parse = S["parse_paths"]
eq("parse: one escaped path", parse(b"/a/My\\ File\\ (1).png"), (["/a/My File (1).png"], ""))
eq("parse: two paths joined by one space", parse(b"/a/x /b/y\\ z"), (["/a/x", "/b/y z"], ""))
eq("parse: a trailing space is kept as trailer", parse(b"/a/x "), (["/a/x"], " "))
eq("parse: relative path: no", parse(b"a/x"), None)
eq("parse: newline: no", parse(b"/a/x\n"), None)
eq("parse: carriage return: no", parse(b"/a/x\r"), None)
eq("parse: two spaces: no", parse(b"/a/x  /b"), None)
eq("parse: leading space: no", parse(b" /a/x"), None)
eq("parse: dangling backslash: no", parse(b"/a/x\\"), None)
eq("parse: control byte: no", parse(b"/a/\x1bx"), None)
eq("parse: invalid utf-8: no", parse(b"/a/\xff"), None)
eq("parse: empty: no", parse(b""), None)
weird = "/tmp/a b;$(x)'q\"*?[1]{2}<3>|&!#`\\\t.png"
eq("escape then parse round-trips every Ghostty special", parse(esc(weird).encode()), ([weird], ""))
eq("escape matches Ghostty's rule", esc("/a b(1)"), "/a\\ b\\(1\\)")

PC = S["PasteCapture"]
c = PC()
eq("capture: plain bytes forward at once", c.feed(b"abc\x1b[A"), (b"abc\x1b[A", None, b""))
eq("capture: complete paste in one read", c.feed(b"x" + START + b"/p" + END + b"y"), (b"x", b"/p", b"y"))
c = PC()
eq("capture: split start marker is never waited for (1)", c.feed(b"q\x1b[20"), (b"q\x1b[20", None, b""))
eq("capture: split start marker is never waited for (2)", c.feed(b"0~/p" + END), (b"0~/p" + END, None, b""))
c = PC()
eq("capture: end marker split across reads (1)", c.feed(START + b"/p\x1b[20"), (b"", None, b""))
eq("capture: end marker split across reads (2)", c.feed(b"1~z"), (b"", b"/p", b"z"))
c = PC(cap=8)
eq("capture: over the cap forwards everything unchanged", c.feed(START + b"123456789"), (START + b"123456789", None, b""))
eq("capture: over the cap ends capture", c.active, False)
now = [0.0]
c = PC(clock=lambda: now[0])
c.feed(START + b"/half")
eq("capture: before the timeout nothing expires", c.expire(1.9), None)
eq("capture: after the timeout the bytes come back", c.expire(2.0), START + b"/half")

# ---------------------------------------------------------------------------
# End to end
# ---------------------------------------------------------------------------

N = [0]


class Run:
    """One shim process with a pty as its terminal."""

    def __init__(self, env=None, args=("new",), rows=40, cols=100, stdin=None):
        N[0] += 1
        self.dir = os.path.join(SANDBOX, "run%d" % N[0])
        os.makedirs(self.dir)
        self.recv_path = os.path.join(self.dir, "recv")
        self.tty_file = os.path.join(self.dir, "child_tty")
        open(self.recv_path, "wb").close()
        self.m, self.s = os.openpty()
        fcntl.ioctl(self.s, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.attrs_before = termios.tcgetattr(self.s)
        e = dict(os.environ)
        e.pop("RW_PASTE_SHIM", None)
        e["FAKE_RECV"] = self.recv_path
        e["FAKE_CHILD_TTY_FILE"] = self.tty_file
        e.update(env or {})
        self.err = open(os.path.join(self.dir, "stderr"), "wb")
        self.out = bytearray()
        self.stop = False
        self.proc = subprocess.Popen(
            [SHIM] + list(args),
            stdin=self.s if stdin is None else stdin,
            stdout=self.s,
            stderr=self.err,
            env=e,
            start_new_session=True,
            close_fds=True,
        )
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        while not self.stop:
            try:
                r, _, _ = select.select([self.m], [], [], 0.05)
            except (OSError, ValueError):
                return
            if r:
                try:
                    d = os.read(self.m, 65536)
                except OSError:
                    return
                if not d:
                    return
                self.out += d

    def wait(self, pred, timeout=5.0):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if pred():
                return True
            time.sleep(0.02)
        return pred()

    def ready(self):
        return self.wait(lambda: b"READY" in self.out)

    def send(self, data):
        os.write(self.m, data)

    def recv(self):
        with open(self.recv_path, "rb") as f:
            return f.read()

    def child_tty(self):
        try:
            with open(self.tty_file) as f:
                return f.read()
        except OSError:
            return ""

    def quit(self, timeout=5.0):
        self.send(b"\x00QUIT")
        return self.exit_code(timeout)

    def exit_code(self, timeout=5.0):
        try:
            return self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None

    def recv_body(self):
        r = self.recv()
        return r[:-5] if r.endswith(b"\x00QUIT") else r

    def attrs_restored(self):
        # PENDIN is set by the kernel itself when a tty goes back to
        # canonical mode (it asks for pending input to be reprinted); it is
        # not an attribute the shim could leave behind.
        def norm(a):
            a = list(a)
            a[3] &= ~getattr(termios, "PENDIN", 0)
            return a
        return norm(termios.tcgetattr(self.s)) == norm(self.attrs_before)

    def close(self):
        if self.proc.poll() is None:
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except OSError:
                pass
            try:
                self.proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        self.stop = True
        self.reader.join(1)
        for fd in (self.m, self.s):
            try:
                os.close(fd)
            except OSError:
                pass
        self.err.close()


def lines(path):
    try:
        with open(path) as f:
            return [l for l in f.read().split("\n") if l]
    except OSError:
        return []


def reset_logs():
    for k in ("FAKE_MESSAGES", "FAKE_LOOKUP_TTYS", "FAKE_SCP_LOG"):
        open(os.environ[k], "w").close()


def paste(*paths):
    return START + " ".join(esc(p) for p in paths).encode() + END


assets = os.path.join(WS, "assets")
os.makedirs(assets, exist_ok=True)
shot = os.path.join(assets, "shot 1 (copy).png")
with open(shot, "wb") as f:
    f.write(b"\x89PNG fake")
other = os.path.join(os.environ["HOME"], "Desktop", "note.txt")
os.makedirs(os.path.dirname(other), exist_ok=True)
with open(other, "w") as f:
    f.write("note")
remote_shot = os.path.join(WORKER_HOME, "Developer", "idol-app", "assets", "shot 1 (copy).png")
remote_other = os.path.join(WORKER_HOME, "Desktop", "note.txt")
REMOTE = {"FAKE_ENDPOINT": "ep000001", "FAKE_PANE": "%5"}

# --- 1. plain bytes pass through byte for byte ---------------------------------
reset_logs()
r = Run()
ok("pass-through: child started", r.ready())
pieces = [
    b"hello world\r",
    b"\x1b",  # lone ESC
    b"\x1b[<0;10;5M\x1b[<0;10;5m",  # SGR mouse press/release
    b"\x1b[M #!",  # X10 mouse
    START + b"some text\nwith a newline" + END,  # paste of ordinary text
    START + b"/no/such/file.png" + END,  # path-shaped, missing
    START + esc(assets).encode() + END,  # a directory
    b"\x03\x04\x1a\x1c\x7f",  # control keys are bytes in raw mode
    bytes(range(256)),
]
want = b""
for p in pieces:
    r.send(p)
    want += p
    time.sleep(0.03)
ok("pass-through: every byte arrived", r.wait(lambda: len(r.recv()) >= len(want)))
eq("pass-through: identical byte for byte", r.recv(), want)
eq("pass-through: exit 0", r.quit(), 0)
ok("pass-through: terminal attributes restored", r.attrs_restored())
eq("pass-through: no pane lookup for non-files", lines(os.environ["FAKE_LOOKUP_TTYS"]), [])
r.close()

# --- 2. one existing file into a remote pane is rewritten ------------------------
reset_logs()
r = Run(env=REMOTE)
ok("remote: child started", r.ready())
r.send(paste(shot))
want = paste(remote_shot)
ok("remote: rewritten paste arrived", r.wait(lambda: len(r.recv()) >= len(want)))
eq("remote: the child got the worker path, escaped, inside the brackets", r.recv(), want)
ok("remote: the file is on the worker", os.path.isfile(remote_shot))
eq("remote: the lookup targeted this client's tty (the inner pty)",
   lines(os.environ["FAKE_LOOKUP_TTYS"]), [r.child_tty()])
ok("remote: the inner tty is not the outer terminal", r.child_tty() != os.ttyname(r.s))
r.send(b"after")
ok("remote: relaying continues", r.wait(lambda: r.recv().endswith(b"after")))
eq("remote: no display-message on success", lines(os.environ["FAKE_MESSAGES"]), [])
eq("remote: exit 0", r.quit(), 0)
ok("remote: terminal attributes restored", r.attrs_restored())
log = "\n".join(lines(os.path.join(os.environ["TMUX_REMOTE_WORKSPACES_STATE_DIR"], "paste-shim.log")))
ok("remote: the log has the intercept decision", "copied 1 file(s)" in log, log)
r.close()

reset_logs()
r = Run(env=REMOTE)
r.ready()
r.send(paste(shot, other))
want = paste(remote_shot, remote_other)
r.wait(lambda: len(r.recv()) >= len(want))
eq("remote: two files are rewritten in order, one space apart", r.recv(), want)
r.quit()
r.close()

# --- 3. non-existent path ----------------------------------------------------------
reset_logs()
r = Run(env=REMOTE)
r.ready()
p = START + b"/Users/nobody/missing.png" + END
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("missing file: pasted unchanged", r.recv(), p)
eq("missing file: no lookup, no message",
   (lines(os.environ["FAKE_LOOKUP_TTYS"]), lines(os.environ["FAKE_MESSAGES"])), ([], []))
r.quit()
r.close()

# --- 4. local pane -------------------------------------------------------------------
reset_logs()
r = Run(env={"FAKE_ENDPOINT": "", "FAKE_PANE": "%9"})
r.ready()
p = paste(shot)
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("local pane: pasted unchanged", r.recv(), p)
eq("local pane: looked up once", len(lines(os.environ["FAKE_LOOKUP_TTYS"])), 1)
eq("local pane: no copy, no message", (lines(os.environ["FAKE_SCP_LOG"]), lines(os.environ["FAKE_MESSAGES"])), ([], []))
r.quit()
r.close()

reset_logs()
r = Run(env=dict(REMOTE, FAKE_LOOKUP_RC="1"))
r.ready()
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("lookup fails (no server answer): pasted unchanged", r.recv(), p)
r.quit()
r.close()

reset_logs()
r = Run(env=dict(REMOTE, FAKE_LOOKUP_SLEEP="5"))
r.ready()
t0 = time.monotonic()
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p), 6)
dt = time.monotonic() - t0
eq("lookup hangs: pasted unchanged", r.recv(), p)
ok("lookup hangs: released by the 2 s lookup timeout (%.2f s)" % dt, 1.8 <= dt < 4.0)
r.quit()
r.close()

# --- 5. scp fails -----------------------------------------------------------------------
reset_logs()
r = Run(env=dict(REMOTE, FAKE_SCP_FAIL="1"))
r.ready()
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("scp fails: the original paste arrives", r.recv(), p)
r.wait(lambda: len(lines(os.environ["FAKE_MESSAGES"])) >= 1, 3)
time.sleep(0.3)
msgs = lines(os.environ["FAKE_MESSAGES"])
eq("scp fails: exactly one display-message", len(msgs), 1)
ok("scp fails: the message goes to this client and says so",
   bool(msgs) and msgs[0].startswith(r.child_tty() + "\t") and "failed" in msgs[0], msgs)
r.quit()
r.close()

# --- 6. scp sleeps past the deadline; output keeps flowing; queued input in order -------
reset_logs()
r = Run(env=dict(REMOTE, FAKE_SCP_SLEEP="23.4567", FAKE_CHILD_TICK="0.2"))
r.ready()
t0 = time.monotonic()
r.send(p)
time.sleep(0.3)
r.send(b"typed during the copy")
time.sleep(0.2)
ticks_at_1 = r.out.count(b"TICK")
time.sleep(4.0)
ticks_at_5 = r.out.count(b"TICK")
ok("deadline: output kept flowing while the copy was pending (%d ticks in 4 s)" % (ticks_at_5 - ticks_at_1),
   ticks_at_5 - ticks_at_1 >= 10)
eq("deadline: nothing reached the child yet", r.recv(), b"")
want = p + b"typed during the copy"
r.wait(lambda: len(r.recv()) >= len(want), 6)
dt = time.monotonic() - t0
eq("deadline: original paste, then the queued input", r.recv(), want)
ok("deadline: released at the 8 s deadline (%.2f s)" % dt, 7.8 <= dt < 9.5)
r.wait(lambda: len(lines(os.environ["FAKE_MESSAGES"])) >= 1, 3)
time.sleep(0.3)
msgs = lines(os.environ["FAKE_MESSAGES"])
ok("deadline: exactly one display-message, saying it timed out", len(msgs) == 1 and "timed out" in msgs[0], msgs)
leftover = subprocess.run(["pgrep", "-f", "sleep 23.4567"], stdout=subprocess.PIPE).stdout
eq("deadline: the copy's process group was killed", leftover, b"")
eq("deadline: exit 0", r.quit(), 0)
r.close()

# --- 7. input typed during a pending copy arrives after the paste, in order ------------
reset_logs()
r = Run(env=dict(REMOTE, FAKE_SCP_SLEEP="0.8"))
r.ready()
r.send(paste(other))
time.sleep(0.1)
r.send(b"x")
r.send(b"yz" + START + b"second paste" + END + b"!")
want = paste(remote_other) + b"xyz" + START + b"second paste" + END + b"!"
r.wait(lambda: len(r.recv()) >= len(want), 5)
eq("queued input: arrives after the rewritten paste, in order", r.recv(), want)
r.quit()
r.close()

# --- 8. child exit code -------------------------------------------------------------------
r = Run(env={"FAKE_CHILD_EXIT": "7"})
r.ready()
eq("exit code: the child's status is propagated", r.quit(), 7)
ok("exit code: terminal attributes restored", r.attrs_restored())
r.close()

# --- 9. 64 KiB+ paste ------------------------------------------------------------------------
reset_logs()
r = Run(env=REMOTE)
r.ready()
big = START + b"/" + b"a" * 70000 + END
r.send(big)
r.wait(lambda: len(r.recv()) >= len(big), 5)
eq("64 KiB+ paste: passes through unchanged", r.recv(), big)
eq("64 KiB+ paste: no lookup", lines(os.environ["FAKE_LOOKUP_TTYS"]), [])
r.quit()
r.close()

# --- 10. split start marker ------------------------------------------------------------------
reset_logs()
r = Run(env=REMOTE)
r.ready()
whole = paste(shot)
r.send(whole[:4])
time.sleep(0.3)
r.send(whole[4:])
r.wait(lambda: len(r.recv()) >= len(whole))
eq("split start marker: passes through unchanged", r.recv(), whole)
eq("split start marker: no lookup", lines(os.environ["FAKE_LOOKUP_TTYS"]), [])
r.quit()
r.close()

# --- 11. start marker without an end marker ---------------------------------------------------
r = Run()
r.ready()
t0 = time.monotonic()
r.send(START + b"/never/ends")
r.wait(lambda: len(r.recv()) > 0, 4)
dt = time.monotonic() - t0
eq("no end marker: forwarded unchanged", r.recv(), START + b"/never/ends")
ok("no end marker: after the 2 s capture timeout (%.2f s)" % dt, 1.9 <= dt < 3.0)
r.send(b"more")
r.wait(lambda: r.recv().endswith(b"more"))
eq("no end marker: relaying continues", r.recv(), START + b"/never/ends" + b"more")
r.quit()
r.close()

# --- 12. window size ------------------------------------------------------------------------------
def tty_size(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    try:
        return struct.unpack("HHHH", fcntl.ioctl(fd, termios.TIOCGWINSZ, b"\0" * 8))[:2]
    finally:
        os.close(fd)


r = Run(rows=33, cols=111)
r.ready()
eq("winsize: copied before the child starts", tty_size(r.child_tty()), (33, 111))
fcntl.ioctl(r.s, termios.TIOCSWINSZ, struct.pack("HHHH", 50, 160, 0, 0))
os.kill(r.proc.pid, signal.SIGWINCH)
ok("winsize: SIGWINCH re-copies the size", r.wait(lambda: tty_size(r.child_tty()) == (50, 160), 2))
r.quit()
r.close()

# --- 13. terminal gone, SIGTERM -----------------------------------------------------------------
r = Run()
r.ready()
r.stop = True
r.reader.join(1)
os.close(r.m)
r.m = None
code = r.exit_code(6)
ok("terminal gone: the shim exits and hangs up the child (exit %r)" % code, code is not None)
r.m = os.open("/dev/null", os.O_RDONLY)
r.close()

r = Run()
r.ready()
os.kill(r.proc.pid, signal.SIGTERM)
code = r.exit_code(6)
ok("SIGTERM: the shim exits (exit %r)" % code, code is not None)
ok("SIGTERM: terminal attributes restored", r.attrs_restored())
r.close()

# --- 14. tmux suspend-client (prefix C-z) -------------------------------------------------------
# a) No job control above the shim (this harness: the shim leads its own
#    session, so its own SIGTSTP is discarded): the client is continued at
#    once and the terminal keeps working.
r = Run()
r.ready()
r.send(b"\x00STOP")
ok("suspend without job control: the client is continued", r.wait(lambda: b"RESUMED" in r.out, 4))
r.send(b"\r")
ok("suspend without job control: raw mode is back (CR arrives as CR)",
   r.wait(lambda: r.recv().endswith(b"\x00STOP\r"), 3), r.recv()[-20:])
eq("suspend without job control: exit 0", r.quit(), 0)
r.close()

# b) Under job control, as zsh runs it: a launcher leads the session, puts
#    the shim in a process group of its own, waits for it with WUNTRACED,
#    then continues the group (`fg`).
LAUNCHER = r"""
import os, signal, sys, termios, time
report = sys.argv[1]
def say(s):
    with open(report, "a") as f:
        f.write(s + "\n")
before = termios.tcgetattr(0)
pid = os.fork()
if pid == 0:
    os.setpgid(0, 0)
    os.execv(sys.argv[2], sys.argv[2:])
os.setpgid(pid, pid)
while True:
    p, st = os.waitpid(pid, os.WUNTRACED)
    if os.WIFSTOPPED(st):
        a = termios.tcgetattr(0)
        a[3] &= ~getattr(termios, "PENDIN", 0)
        before[3] &= ~getattr(termios, "PENDIN", 0)
        say("STOPPED restored=%s" % (a == before))
        time.sleep(0.3)
        os.killpg(pid, signal.SIGCONT)
        continue
    say("EXIT %d" % (os.WEXITSTATUS(st) if os.WIFEXITED(st) else 128 + os.WTERMSIG(st)))
    break
"""
report = os.path.join(SANDBOX, "launcher.report")


class LaunchedRun(Run):
    def __init__(self):
        N[0] += 1
        self.dir = os.path.join(SANDBOX, "run%d" % N[0])
        os.makedirs(self.dir)
        self.recv_path = os.path.join(self.dir, "recv")
        self.tty_file = os.path.join(self.dir, "child_tty")
        open(self.recv_path, "wb").close()
        self.m, self.s = os.openpty()
        self.attrs_before = termios.tcgetattr(self.s)
        e = dict(os.environ)
        e.pop("RW_PASTE_SHIM", None)
        e["FAKE_RECV"] = self.recv_path
        e["FAKE_CHILD_TTY_FILE"] = self.tty_file
        self.err = open(os.path.join(self.dir, "stderr"), "wb")
        self.out = bytearray()
        self.stop = False
        self.proc = subprocess.Popen(
            ["/usr/bin/python3", "-c", LAUNCHER, report, SHIM, "new"],
            stdin=self.s, stdout=self.s, stderr=self.err, env=e,
            start_new_session=True, close_fds=True)
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()


r = LaunchedRun()
ok("suspend under job control: child started", r.ready())
r.send(b"\x00STOP")
ok("suspend under job control: the shim stopped itself (the shell sees a suspended job)",
   r.wait(lambda: any(l.startswith("STOPPED") for l in lines(report)), 4), lines(report))
ok("suspend under job control: the terminal was restored while stopped",
   "STOPPED restored=True" in lines(report), lines(report))
ok("suspend under job control: fg continues the client", r.wait(lambda: b"RESUMED" in r.out, 4))
r.send(b"\r")
ok("suspend under job control: raw mode is back after fg",
   r.wait(lambda: r.recv().endswith(b"\x00STOP\r"), 3), r.recv()[-20:])
r.send(b"\x00QUIT")
ok("suspend under job control: exit 0 afterwards", r.wait(lambda: "EXIT 0" in lines(report), 5), lines(report))
r.close()

# --- 15. never nests; no tty: plain tmux ------------------------------------------------------------
r = Run(env={"RW_PASTE_SHIM": "1"})
r.ready()
eq("RW_PASTE_SHIM=1: runs tmux directly on the same terminal", r.child_tty(), os.ttyname(r.s))
r.quit()
r.close()

r = Run(stdin=subprocess.DEVNULL, args=("-V",))
eq("stdin not a tty: runs tmux directly", r.exit_code(5), 0)
r.close()

r = Run()
r.ready()
with open(r.tty_file + ".env") as f:
    eq("the child runs with RW_PASTE_SHIM=1 (nothing nests)", f.read(), "1")
r.quit()
r.close()

err = b""
for i in range(1, N[0] + 1):
    with open(os.path.join(SANDBOX, "run%d" % i, "stderr"), "rb") as f:
        err += f.read()
eq("no shim wrote to stderr in any run", err, b"")

print("paste_shim_driver: %d passed, %d failed" % (passed, failed), flush=True)
sys.exit(0 if failed == 0 else 1)
