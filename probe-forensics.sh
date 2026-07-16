#!/usr/bin/env bash
# Forensic probe for the #16000 failure: captures WHERE the temp-file handoff
# breaks, using a disposable container (same environment as ./repro.sh).
#
#   ./probe-forensics.sh [arch]     # arm64 (default) | amd64
#
# Captures into logs/:
#   forensics-strace-excerpt.log  — syscall timeline around mgr/Temp
#   forensics-watcher.log         — 20 Hz watch of mgr/Temp during the load
#
# Requires Docker only (strace is installed inside the disposable container).
set -euo pipefail

ARCH="${1:-auto}"
if [ "$ARCH" = "auto" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *) echo "unsupported host arch: $(uname -m) — pass arm64|amd64 explicitly"; exit 1 ;;
  esac
fi
IMG="intersystems/iris-community:2026.1"
NAME="pyprod-16000-forensics"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mkdir -p "$HERE/logs"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --platform "linux/$ARCH" \
  --cap-add SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$HERE/assets:/probe:ro" -e ISC_CPF_MERGE_FILE=/probe/merge.cpf "$IMG" >/dev/null

echo "==> waiting for IRIS (running)..."
up=0
for _ in $(seq 1 60); do
  docker exec -u irisowner "$NAME" iris qlist 2>/dev/null | grep -q 'running,' && { up=1; break; }
  sleep 3
done
[ "$up" = 1 ] || { echo "✗ IRIS did not start"; exit 1; }

docker exec -u root "$NAME" bash -c '
set -e
apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq strace >/dev/null 2>&1
export IRISINSTALLDIR=/usr/irissys LD_LIBRARY_PATH=/usr/irissys/bin:/usr/irissys/dev
export IRISUSERNAME=superuser IRISPASSWORD=SYS IRISNAMESPACE=ENSEMBLE PYTHONPATH=/usr/irissys/lib/python
python3 -m pip install --quiet --break-system-packages intersystems_pyprod >/dev/null 2>&1
export PATH=/root/.local/bin:$PATH
mkdir -p /tmp/forensics

# 1) high-frequency watcher on the temp dir
( while :; do
    for f in /usr/irissys/mgr/Temp/*; do
      [ -e "$f" ] || continue
      stat -c "%.19y %U:%G %a %s bytes %n" "$f" >> /tmp/forensics/watch.log 2>/dev/null
    done
    sleep 0.05
  done ) & W=$!

# 2) strace of the loader (file syscalls)
mlog_before=$(wc -l < /usr/irissys/mgr/messages.log)
strace -f -e trace=%file -s 120 -o /tmp/forensics/trace.log \
  intersystems_pyprod /probe/interop_example.py >/dev/null 2>&1 || true
kill $W 2>/dev/null || true
mlog_after=$(wc -l < /usr/irissys/mgr/messages.log)

{
  echo "kernel: $(uname -r) · io_uring_disabled: $(cat /proc/sys/kernel/io_uring_disabled 2>/dev/null || echo n/a)"
  echo "messages.log new lines during load: $((mlog_after - mlog_before))"
  echo "watcher snapshots of mgr/Temp during load:"
  if [ -s /tmp/forensics/watch.log ]; then sort -u /tmp/forensics/watch.log; else echo "(none — file never observed on disk at 20 Hz)"; fi
} > /tmp/forensics/watcher-summary.log

grep -n -B2 -A6 "mgr/Temp" /tmp/forensics/trace.log | head -60 > /tmp/forensics/strace-excerpt.log
'
docker cp "$NAME:/tmp/forensics/strace-excerpt.log" "$HERE/logs/forensics-strace-excerpt.log" >/dev/null
docker cp "$NAME:/tmp/forensics/watcher-summary.log" "$HERE/logs/forensics-watcher.log" >/dev/null

echo "──────────────────────────────────────────────────────"
echo "Key finding (see logs/forensics-strace-excerpt.log):"
grep -E "O_RDWR\|O_NOCTTY|O_CREAT|unlinkat" "$HERE/logs/forensics-strace-excerpt.log" | head -6
echo
echo "Watcher summary:"
head -3 "$HERE/logs/forensics-watcher.log"
echo "Logs written to logs/forensics-*.log"
