#!/usr/bin/env bash
# Transport fakes for the drop-to-remote paste tests (C5). Sourced after
# lib.sh's rw_test_sandbox. Installs into $SANDBOX/bin:
#   ssh-rw  RW_SSH_BIN: `-O check` answers from FAKE_MASTER (shared | stream
#           | none; FAKE_CHECK_HANG=<s> makes a check hang like a wedged
#           master; FAKE_MASTER_DEAD=1 makes sessions through a master hang
#           while direct ones work); everything else goes to lib.sh's
#           same-host fake ssh.
#           Every call is logged to FAKE_TRANSPORT_LOG.
#   sftp    RW_SFTP_BIN: runs a `-b` batch (mkdir, put, rename, ln as
#           link(2) failing on an existing name, rm; a leading
#           "-" ignores errors; "..." quoting with \" escapes) on this host.
#           FAKE_SFTP_SLEEP=<s> sleeps first (a real `sleep` process),
#           FAKE_SFTP_FAIL=1 fails the first put, FAKE_SFTP_HOOK=<cmd> runs
#           first. Logs each command to FAKE_SFTP_LOG.

paste_fakes_install() {
  export FAKE_TRANSPORT_LOG="$SANDBOX/transport.log"
  export FAKE_SFTP_LOG="$SANDBOX/sftp.log"
  : >"$FAKE_TRANSPORT_LOG"
  : >"$FAKE_SFTP_LOG"

  cat >"$SANDBOX/bin/ssh-rw" <<'EOF'
#!/usr/bin/env bash
check=0 cp=""
prev=""
for a in "$@"; do
  [ "$a" = -O ] && check=1
  [ "$prev" = -o ] && case "$a" in ControlPath=*) cp="${a#ControlPath=}" ;; esac
  prev="$a"
done
if [ "$check" = 1 ]; then
  printf 'check %s\n' "${cp:-shared}" >>"${FAKE_TRANSPORT_LOG:-/dev/null}"
  [ -n "${FAKE_CHECK_HANG:-}" ] && sleep "$FAKE_CHECK_HANG"
  case "${FAKE_MASTER:-none}" in
    shared) [ -z "$cp" ] ;;
    stream) case "$cp" in *rw-stream*) true ;; *) false ;; esac ;;
    *) false ;;
  esac
  exit $?
fi
printf 'ssh %s\n' "$*" >>"${FAKE_TRANSPORT_LOG:-/dev/null}"
# FAKE_MASTER_DEAD=1: the master answers -O check, but a session through it
# hangs (its TCP connection died while the laptop slept); direct works.
if [ "${FAKE_MASTER_DEAD:-0}" = 1 ] && [ "$cp" != none ]; then
  exec sleep 9.8765
fi
exec "$(dirname "$0")/ssh" "$@"
EOF

  cat >"$SANDBOX/bin/sftp" <<'EOF'
#!/usr/bin/python3
import os, re, shutil, subprocess, sys
args = sys.argv[1:]
log = os.environ.get("FAKE_SFTP_LOG", "/dev/null")
with open(os.environ.get("FAKE_TRANSPORT_LOG", "/dev/null"), "a") as f:
    f.write("sftp " + " ".join(args) + "\n")
batch = args[args.index("-b") + 1]
if os.environ.get("FAKE_SFTP_HOOK"):
    subprocess.run(["bash", "-c", os.environ["FAKE_SFTP_HOOK"]])
if os.environ.get("FAKE_SFTP_SLEEP"):
    subprocess.run(["sleep", os.environ["FAKE_SFTP_SLEEP"]])
if os.path.exists(os.environ.get("FAKE_SSH_DOWN", "/nonexistent")) or os.environ.get("FAKE_SFTP_DOWN") == "1":
    sys.stderr.write("ssh: connect to host: Connection refused\n")
    sys.exit(255)
tok = re.compile(r'"((?:[^"\\]|\\.)*)"|(\S+)')
def unq(m):
    return re.sub(r'\\(["\\])', r"\1", m.group(1)) if m.group(1) is not None else m.group(2)
for line in open(batch):
    line = line.strip()
    if not line:
        continue
    lenient = line.startswith("-")
    if lenient:
        line = line[1:]
    words = [unq(m) for m in tok.finditer(line)]
    with open(log, "a") as f:
        f.write("\t".join(words) + "\n")
    try:
        if words[0] == "mkdir":
            os.mkdir(words[1])
        elif words[0] == "put":
            if os.environ.get("FAKE_SFTP_FAIL") == "1":
                raise OSError("fake put failure")
            shutil.copyfile(words[1], words[2])
        elif words[0] == "rename":
            os.replace(words[1], words[2])
        elif words[0] == "ln":  # hardlink@openssh.com: EEXIST, never clobbers
            os.link(words[1], words[2])
        elif words[0] == "rm":
            os.unlink(words[1])
        else:
            raise OSError("unknown command " + words[0])
    except OSError as e:
        if not lenient:
            sys.stderr.write("sftp: %s\n" % e)
            sys.exit(1)
EOF
  chmod +x "$SANDBOX/bin/ssh-rw" "$SANDBOX/bin/sftp"
  export RW_SSH_BIN="$SANDBOX/bin/ssh-rw"
  export RW_SFTP_BIN="$SANDBOX/bin/sftp"
}
