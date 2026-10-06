#!/bin/sh
# A stand-in for `java` in Notary.Tools.TLCRunner tests (no JVM needed).
#
# The runner passes JVM args first, so the control directory is the LAST
# argument. Writes its PID to <dir>/pid, then reads one command per line from
# the FIFO <dir>/ctl (created by the test/mapping with mkfifo):
#   progress  -> prints "<n> distinct states found" (n counts up from 1)
#   exit      -> creates <dir>/exited and exits 0
# Any other line is ignored.
#
# The marker is written with a shell redirection, not `touch`: an external
# `touch` is a child process that can outlive this script when the watchdog
# SIGKILLs it, writing the marker after the process is already dead (the
# mapping would then see os go killed -> exited, which the spec forbids).
for arg in "$@"; do dir="$arg"; done

echo "$$" > "$dir/pid.tmp" && mv "$dir/pid.tmp" "$dir/pid"

exec 3<"$dir/ctl"
n=0
while IFS= read -r line <&3; do
  case "$line" in
    progress)
      n=$((n + 1))
      echo "$n distinct states found"
      ;;
    exit)
      : > "$dir/exited"
      exit 0
      ;;
  esac
done
