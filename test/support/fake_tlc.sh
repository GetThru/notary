#!/bin/sh
# A stand-in for `java` in Outlaw.Tools.TLCRunner tests (no JVM needed).
#
# The runner passes JVM args first, so the control directory is the LAST
# argument. Writes its PID to <dir>/pid, then reads one command per line from
# the FIFO <dir>/ctl (created by the test/mapping with mkfifo):
#   progress  -> prints "<n> distinct states found" (n counts up from 1)
#   exit      -> touches <dir>/exited and exits 0
# Any other line is ignored.
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
      touch "$dir/exited"
      exit 0
      ;;
  esac
done
