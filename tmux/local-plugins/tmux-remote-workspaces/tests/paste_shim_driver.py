#!/usr/bin/python3
"""Cases for libexec/rw-paste-shim and the zsh wrapper (C4 in
docs/tasks/drop-to-remote-paste.md, and the W2 regression cases).

Run by test_paste_shim.sh, which builds the sandbox and the fakes (fake
`tmux` on PATH, fake child, fake ssh/sftp, endpoint record) and exports
SANDBOX, WS, FAKE_*. Two layers:
  - unit: the pure parts loaded with runpy (parse_paths, ghostty_escape,
    PasteCapture, in_scope);
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
HOME = os.environ["HOME"]
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
signal.alarm(240)

# ---------------------------------------------------------------------------
# Unit: classifier, scope and capture state machine
# ---------------------------------------------------------------------------

parse = S["parse_paths"]
eq("parse: one escaped path", parse(b"/a/My\\ File\\ (1).png"), (["/a/My File (1).png"], ""))
eq("parse: two paths joined by one space", parse(b"/a/x /b/y\\ z"), (["/a/x", "/b/y z"], ""))
eq("parse: a trailing space is kept as trailer", parse(b"/a/x "), (["/a/x"], " "))
eq("parse: relative path: no", parse(b"a/x"), None)
eq("parse: second token relative: no", parse(b"/a/x b"), None)
eq("parse: newline: no", parse(b"/a/x\n"), None)
eq("parse: carriage return: no", parse(b"/a/x\r"), None)
eq("parse: two spaces: no", parse(b"/a/x  /b"), None)
eq("parse: leading space: no", parse(b" /a/x"), None)
eq("parse: dangling backslash: no", parse(b"/a/x\\"), None)
eq("parse: control byte: no", parse(b"/a/\x1bx"), None)
eq("parse: unescaped tab: no", parse(b"/a/\tx"), None)
eq("parse: escaped tab: yes", parse(b"/a/\\\tx"), (["/a/\tx"], ""))
eq("parse: invalid utf-8: no", parse(b"/a/\xff"), None)
eq("parse: empty: no", parse(b""), None)
eq("parse: a token longer than PATH_MAX: no", parse(b"/" + b"a" * 1100), None)
weird = "/tmp/a b;$(x)'q\"*?[1]{2}<3>|&!#`\\\t.png"
eq("escape then parse round-trips every Ghostty special", parse(esc(weird).encode()), ([weird], ""))
eq("escape matches Ghostty's rule", esc("/a b(1)"), "/a\\ b\\(1\\)")

# W2-12: the relay-thread parse is cheap on a 64 KiB single-line paste,
# including the worst paste that is still a candidate (60 paths of 1000
# characters).
worst = 0.0
for payload in (b"a" * 64000, b"/" + b"a" * 63999, b"/ab " * 16000, b"/" + b"\\a" * 31999,
                (b"/" + b"a" * 1000 + b" ") * 60):
    t = time.perf_counter()
    for _ in range(5):
        parse(payload)
    worst = max(worst, (time.perf_counter() - t) / 5 * 1000)
ok("parse: a 64 KiB paste costs under 5 ms on the relay thread (worst %.2f ms)" % worst, worst < 5.0)
eq("parse: more than 64 paths: no", parse(b"/a " * 70 + b"/a"), None)

in_scope = S["in_scope"]
real_home = os.path.realpath(HOME)
ok("scope: under $HOME", in_scope(os.path.join(HOME, "x.png"), [real_home]))
ok("scope: /tmp (via /private/tmp)", in_scope("/tmp/x.png", ["/private/tmp"]))
ok("scope: /etc/hosts is out", not in_scope("/etc/hosts", S["scope_roots"]()))
ok("scope: /Applications is out", not in_scope("/Applications/Safari.app/Contents/Info.plist", S["scope_roots"]()))

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
    """One shim process (or `argv`) with a pty as its terminal."""

    def __init__(self, env=None, args=("new",), rows=40, cols=100, stdin=None, argv=None):
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
            argv or ([SHIM] + list(args)),
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

    def child_env(self):
        try:
            with open(self.tty_file + ".env") as f:
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
    for k in ("FAKE_MESSAGES", "FAKE_LOOKUP_TTYS", "FAKE_SFTP_LOG", "FAKE_TRANSPORT_LOG"):
        open(os.environ[k], "w").close()


def paste(*paths):
    return START + " ".join(esc(p) for p in paths).encode() + END


FRESH = [0]


def fresh(name="drop.png"):
    """A new laptop file under the workspace and its worker path."""
    FRESH[0] += 1
    d = os.path.join(WS, "fresh%d" % FRESH[0])
    os.makedirs(d)
    p = os.path.join(d, name)
    with open(p, "wb") as f:
        f.write(b"fresh %d" % FRESH[0])
    return p, os.path.join(WORKER_HOME, "Developer", "idol-app", "fresh%d" % FRESH[0], name)


def messages():
    return lines(os.environ["FAKE_MESSAGES"])


assets = os.path.join(WS, "assets")
os.makedirs(assets, exist_ok=True)
shot = os.path.join(assets, "shot 1 (copy).png")
with open(shot, "wb") as f:
    f.write(b"\x89PNG fake")
other = os.path.join(HOME, "Desktop", "note.txt")
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
eq("remote: no failure message (at most the 'copying' progress line)",
   [m for m in messages() if "copying 1 file(s) to fakeworker" not in m], [])
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

# --- 3. non-existent path; out of scope --------------------------------------------------
reset_logs()
r = Run(env=REMOTE)
r.ready()
p = START + b"/Users/nobody/missing.png" + END
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("missing file: pasted unchanged", r.recv(), p)
eq("missing file: no lookup, no message",
   (lines(os.environ["FAKE_LOOKUP_TTYS"]), messages()), ([], []))
p = START + b"/etc/hosts" + END
r.send(p)
r.wait(lambda: r.recv().endswith(p))
ok("W2-3 scope: /etc/hosts (outside the scope) is pasted unchanged", r.recv().endswith(p))
eq("W2-3 scope: no lookup, no transport", (lines(os.environ["FAKE_LOOKUP_TTYS"]),
   lines(os.environ["FAKE_TRANSPORT_LOG"])), ([], []))
r.quit()
r.close()

# --- 4. local pane; lookup failures; a pane in a mode ------------------------------------------
reset_logs()
r = Run(env={"FAKE_ENDPOINT": "", "FAKE_PANE": "%9"})
r.ready()
p = paste(shot)
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("local pane: pasted unchanged", r.recv(), p)
eq("local pane: looked up once", len(lines(os.environ["FAKE_LOOKUP_TTYS"])), 1)
eq("local pane: no copy, no message", (lines(os.environ["FAKE_TRANSPORT_LOG"]), messages()), ([], []))
r.quit()
r.close()

reset_logs()
r = Run(env=dict(REMOTE, FAKE_PANE_IN_MODE="1"))
r.ready()
r.send(p)
r.wait(lambda: len(r.recv()) >= len(p))
eq("W2-8 pane in a mode (copy mode, a chooser): pasted unchanged", r.recv(), p)
eq("W2-8 pane in a mode: no copy", lines(os.environ["FAKE_TRANSPORT_LOG"]), [])
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
ok("lookup hangs: released by the 2 s lookup timeout (%.2f s)" % dt, 1.8 <= dt < 3.5)
r.quit()
r.close()

# --- 5. the copy fails ---------------------------------------------------------------------
reset_logs()
f5, _ = fresh()
p5 = paste(f5)
r = Run(env=dict(REMOTE, FAKE_SFTP_FAIL="1"))
r.ready()
r.send(p5)
r.wait(lambda: len(r.recv()) >= len(p5))
eq("copy fails: the original paste arrives", r.recv(), p5)
r.wait(lambda: len(messages()) >= 1, 3)
time.sleep(0.3)
msgs = messages()
eq("copy fails: exactly one display-message", len(msgs), 1)
ok("copy fails: the message goes to this client and says so",
   bool(msgs) and msgs[0].startswith(r.child_tty() + "\t") and "failed" in msgs[0], msgs)
r.quit()
r.close()

# --- 6. the copy hangs past the 4 s deadline; output keeps flowing; queued input in order ------
reset_logs()
f6, _ = fresh()
p6 = paste(f6)
r = Run(env=dict(REMOTE, FAKE_SFTP_SLEEP="23.4567", FAKE_CHILD_TICK="0.1"))
r.ready()
t0 = time.monotonic()
r.send(p6)
time.sleep(0.3)
r.send(b"typed during the copy")
time.sleep(0.2)
ticks_a = r.out.count(b"TICK")
time.sleep(2.5)
ticks_b = r.out.count(b"TICK")
ok("deadline: output kept flowing while the copy was pending (%d ticks in 2.5 s)" % (ticks_b - ticks_a),
   ticks_b - ticks_a >= 12)
eq("deadline: nothing reached the child yet", r.recv(), b"")
want = p6 + b"typed during the copy"
r.wait(lambda: len(r.recv()) >= len(want), 4)
dt = time.monotonic() - t0
eq("deadline: original paste, then the queued input", r.recv(), want)
ok("W2-2 deadline: released at the 4 s deadline (%.2f s)" % dt, 3.9 <= dt < 5.0)
r.wait(lambda: len(messages()) >= 2, 3)
time.sleep(0.3)
msgs = messages()
ok("W2-2 progress: 'copying 1 file(s) to fakeworker' shown while the copy ran",
   any("rw: copying 1 file(s) to fakeworker…" in m for m in msgs), msgs)
ok("deadline: exactly one failure message, saying it timed out",
   len([m for m in msgs if "timed out" in m]) == 1 and len(msgs) == 2, msgs)
leftover = subprocess.run(["pgrep", "-f", "sleep 23.4567"], stdout=subprocess.PIPE).stdout
eq("deadline: the copy's process group was killed", leftover, b"")
eq("deadline: exit 0", r.quit(), 0)
r.close()

# --- 7. input typed during a pending copy arrives after the paste, in order ------------
reset_logs()
f7, w7 = fresh()
r = Run(env=dict(REMOTE, FAKE_SFTP_SLEEP="0.8"))
r.ready()
r.send(paste(f7))
time.sleep(0.1)
r.send(b"x")
r.send(b"yz" + START + b"second paste" + END + b"!")
want = paste(w7) + b"xyz" + START + b"second paste" + END + b"!"
r.wait(lambda: len(r.recv()) >= len(want), 5)
eq("queued input: arrives after the rewritten paste, in order", r.recv(), want)
time.sleep(0.2)
ok("W2-2 progress: a copy longer than 300 ms shows one 'copying' message",
   [m for m in messages() if "copying 1 file(s)" in m] != [] and len(messages()) == 1, messages())
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

# --- 13. terminal gone, SIGTERM (W2-4: the resets reach the terminal) -------------------------------
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

r = Run(env={"FAKE_CHILD_RESET_ON_HUP": "1"})
r.ready()
os.kill(r.proc.pid, signal.SIGTERM)
code = r.exit_code(6)
ok("SIGTERM: the shim exits (exit %r)" % code, code is not None)
ok("W2-4 SIGTERM: the server's terminal resets written on hang-up reach the terminal",
   r.wait(lambda: b"<RESET>" in r.out, 1), bytes(r.out[-80:]))
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

# W2-1 (probe p2): the server stops reading the client tty, then the client
# stops itself; 4 KiB of input arrives in that window. The shim must not
# block writing it: it must still reach the suspend, continue the client,
# and deliver every byte in order afterwards.
r = Run(env={"FAKE_CHILD_STOP_DELAY": "0.3"})
r.ready()
r.send(b"\x00STOP")
time.sleep(0.05)
burst = b"".join(b"k%04d" % i for i in range(820))  # 4100 bytes
threading.Thread(target=lambda: r.send(burst), daemon=True).start()
ok("W2-1 suspend with 4 KiB in flight: the client is continued (no blocked write)",
   r.wait(lambda: b"RESUMED" in r.out, 5), bytes(r.out[-60:]))
ok("W2-1 suspend with 4 KiB in flight: every byte arrives afterwards, in order",
   r.wait(lambda: r.recv().endswith(b"\x00STOP" + burst), 5), len(r.recv()))
eq("W2-1 suspend with 4 KiB in flight: exit 0", r.quit(), 0)
r.close()

# W2-1: a child that stops reading for 2 s while 1 MiB of input arrives: the
# relay keeps the output direction flowing (ticks) and loses nothing.
r = Run(env={"FAKE_CHILD_TICK": "0.1"})
r.ready()
r.send(b"\x00HOLD")
time.sleep(0.1)
mib = b"".join(b"%07d\n" % i for i in range(131072))  # 1 MiB
sender = threading.Thread(target=lambda: r.send(mib), daemon=True)
sender.start()
t_a = r.out.count(b"TICK")
time.sleep(1.5)
t_b = r.out.count(b"TICK")
ok("W2-1 child not reading, 1 MiB pending: output keeps flowing (%d ticks in 1.5 s)" % (t_b - t_a),
   t_b - t_a >= 10)
ok("W2-1 child not reading, 1 MiB pending: everything arrives in order",
   r.wait(lambda: r.recv() == b"\x00HOLD" + mib, 10), len(r.recv()))
eq("W2-1 1 MiB: exit 0", r.quit(), 0)
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
r = Run(argv=["/usr/bin/python3", "-c", LAUNCHER, report, SHIM, "new"])
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

# --- 15. W2-11 (probe p5): EAGAIN on the terminal does not kill the relay --------------------------
r = Run()
r.ready()
fl = fcntl.fcntl(r.s, fcntl.F_GETFL)
fcntl.fcntl(r.s, fcntl.F_SETFL, fl | os.O_NONBLOCK)  # shared description, as a stray program leaves it
thief_stop = [False]


def thief():
    while not thief_stop[0]:
        try:
            os.read(r.s, 1)
        except BlockingIOError:
            pass
        except OSError:
            return


threading.Thread(target=thief, daemon=True).start()
for i in range(2000):
    try:
        os.write(r.m, b"x")
    except OSError:
        break
    if r.proc.poll() is not None:
        break
    time.sleep(0.0005)
thief_stop[0] = True
time.sleep(0.3)
ok("W2-11 EAGAIN storm on the terminal: the shim is still running", r.proc.poll() is None)
r.send(b"after-eagain")
ok("W2-11 EAGAIN storm: relaying continues", r.wait(lambda: r.recv().endswith(b"after-eagain"), 3))
eq("W2-11 EAGAIN storm: exit 0", r.quit(), 0)
fcntl.fcntl(r.s, fcntl.F_SETFL, fl)
r.close()

# --- 16. W2-9 / W2-10: what the child inherits -----------------------------------------------------
disp = os.path.join(SANDBOX, "sigdisp")
r = Run(env={"FAKE_SIGDISP_FILE": disp, "RW_PASTE_SHIM": "1"}, args=("sigdisp",))
r.ready()
eq("W2-9 the child starts with SIGPIPE, SIGXFSZ, SIGINT at their defaults",
   lines(disp), ["PIPE=DEFAULT XFSZ=DEFAULT INT=DEFAULT"])
eq("W2-10 RW_PASTE_SHIM never reaches the child (or a server it starts)", r.child_env(), "unset")
r.quit()
r.close()

# --- 17. routing: never nests; switched off; no tty --------------------------------------------------
r = Run(env={"TMUX": "/tmp/fake,1,0"})
r.ready()
eq("$TMUX set: runs tmux directly on the same terminal", r.child_tty(), os.ttyname(r.s))
r.quit()
r.close()

r = Run(env={"RW_PASTE_SHIM": "0"})
r.ready()
eq("RW_PASTE_SHIM=0: runs tmux directly on the same terminal", r.child_tty(), os.ttyname(r.s))
r.quit()
r.close()

r = Run(stdin=subprocess.DEVNULL, args=("-V",))
eq("stdin not a tty: runs tmux directly", r.exit_code(5), 0)
r.close()

# --- 18. W2-5 / W2-13: the zsh wrapper -------------------------------------------------------------
WRAPPER = os.environ["ZSH_WRAPPER"]


def zsh_run(script, env=None):
    # The sandbox $HOME has no ~/.config/tmux link: point the wrapper at
    # this checkout's shim (a test may override it again).
    return Run(env=env, argv=["/bin/zsh", "-f", "-i", "-c", "source %s; _RW_PASTE_SHIM_BIN=%s; %s"
                              % (WRAPPER, SHIM, script)])


r = zsh_run("_rw_paste_shim_python && print -r -- \"PY=$_RW_PASTE_SHIM_PY\"; tmux new")
r.ready()
ok("W2-5 wrapper: runs the shim on the developer tools' real python3, not the /usr/bin stub",
   b"PY=/" in r.out and b"PY=/usr/bin/python3" not in r.out, bytes(r.out[:200]))
ok("wrapper: `tmux new` goes through the shim", r.child_tty() not in ("", os.ttyname(r.s)),
   (r.child_tty(), os.ttyname(r.s), bytes(r.out[:300])))
r.quit()
r.close()

broken = os.path.join(SANDBOX, "broken-shim")
with open(broken, "w") as f:
    f.write("def oops(:\n")
r = zsh_run("_RW_PASTE_SHIM_BIN=%s; tmux new; print -r -- RC=$?" % broken)
ok("W2-5 wrapper, shim with a syntax error: plain tmux starts instead", r.ready())
eq("W2-5 wrapper, broken shim: tmux runs on the terminal directly", r.child_tty(), os.ttyname(r.s))
r.send(b"\x00QUIT")
ok("W2-5 wrapper, broken shim: tmux's own status is returned", r.wait(lambda: b"RC=0" in r.out, 5))
r.close()

r = zsh_run("tmux new -d -s x; print -r -- RC=$?")
r.ready()
r.send(b"\x00QUIT")
r.wait(lambda: b"RC=" in r.out, 5)
ok("W2-13 wrapper: `tmux new -d` skips the shim", r.child_tty() == os.ttyname(r.s), r.child_tty())
r.close()

err = b""
for i in range(1, N[0] + 1):
    with open(os.path.join(SANDBOX, "run%d" % i, "stderr"), "rb") as f:
        err += f.read()
eq("no run wrote anything to stderr", err, b"")

print("paste_shim_driver: %d passed, %d failed" % (passed, failed), flush=True)
sys.exit(0 if failed == 0 else 1)
