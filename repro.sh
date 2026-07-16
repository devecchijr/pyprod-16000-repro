#!/usr/bin/env bash
# Self-contained reproduction of intersystems/pyprod#11 —
# ERROR #16000 "Internal compiler error" via %SYSTEM.OBJ.LoadStream.
#
# Spins up a DISPOSABLE IRIS container that replicates the pyprod CI job
# (same image, same merge.cpf: ENSEMBLE namespace + Interop + %Service_CallIn,
# superuser/SYS), runs the minimal loader from the issue, prints the verdict,
# and removes everything on exit. Nothing on your machine is touched.
#
# Usage:
#   ./repro.sh [arch] [source] [user] [startup]
#     arch    = auto (default: matches the host) | arm64 | amd64
#     source  = pypi (default)  | main       (main = GitHub tarball of pyprod)
#     user    = root (default)  | irisowner  (pyprod CI runs as root: --user 0:0)
#     startup = entrypoint (default) | cistart
#               (cistart = bare `iris start` as irisowner, exactly like the CI job;
#                entrypoint = the image's normal iris-main entrypoint)
#
# Output: "REPRODUCED (#16000)" or "NOT REPRODUCED (LoadStream OK)".
# Exit codes: 0 = reproduced · 2 = not reproduced · 1 = test infrastructure failure.
set -euo pipefail

ARCH="${1:-auto}"; SOURCE="${2:-pypi}"; RUNAS="${3:-root}"; START="${4:-entrypoint}"
if [ "$ARCH" = "auto" ]; then
  case "$(uname -m)" in
    arm64|aarch64) ARCH=arm64 ;;
    x86_64|amd64)  ARCH=amd64 ;;
    *) echo "unsupported host arch: $(uname -m) — pass arm64|amd64 explicitly"; exit 1 ;;
  esac
fi
IMG="intersystems/iris-community:2026.1"
NAME="pyprod-16000-repro"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

case "$SOURCE" in
  pypi) PKG="intersystems_pyprod" ;;
  main) PKG="https://github.com/intersystems/pyprod/archive/refs/heads/main.tar.gz" ;;
  *) echo "invalid source: $SOURCE (pypi|main)"; exit 1 ;;
esac

echo "==> image=$IMG arch=$ARCH source=$SOURCE user=$RUNAS startup=$START host=$(uname -s)/$(uname -m)"
docker rm -f "$NAME" >/dev/null 2>&1 || true

if [ "$START" = "cistart" ]; then
  # CI replica: neutral entrypoint + manual `iris start` as irisowner.
  docker run -d --name "$NAME" --platform "linux/$ARCH" --user 0:0 \
    --entrypoint tail -v "$HERE/assets:/probe:ro" "$IMG" -f /dev/null >/dev/null
  docker exec -u root "$NAME" bash -c \
    'runuser -u irisowner -- env ISC_CPF_MERGE_FILE=/probe/merge.cpf /usr/irissys/bin/iris start IRIS >/dev/null 2>&1'
else
  docker run -d --name "$NAME" --platform "linux/$ARCH" \
    -v "$HERE/assets:/probe:ro" -e ISC_CPF_MERGE_FILE=/probe/merge.cpf "$IMG" >/dev/null
fi

echo "==> waiting for IRIS (running)..."
# NOTE: qlist must run as irisowner — as root it reports "indeterminate"
# even when the instance is up (matters in cistart mode, where the container
# user is root like in the pyprod CI job).
up=0
for _ in $(seq 1 60); do
  if docker exec -u irisowner "$NAME" iris qlist 2>/dev/null | grep -q 'running,'; then up=1; break; fi
  sleep 3
done
[ "$up" = 1 ] || { echo "✗ IRIS did not start — see: docker logs $NAME"; exit 1; }

out=$(docker exec -u "$RUNAS" "$NAME" bash -c "
export IRISINSTALLDIR=/usr/irissys LD_LIBRARY_PATH=/usr/irissys/bin:/usr/irissys/dev
export IRISUSERNAME=superuser IRISPASSWORD=SYS IRISNAMESPACE=ENSEMBLE
export PYTHONPATH=/usr/irissys/lib/python
python3 -m pip install --quiet --break-system-packages '$PKG' >/dev/null 2>&1
export PATH=\$HOME/.local/bin:/root/.local/bin:\$PATH
echo '── environment:' \$(uname -m) \$(python3 --version 2>&1) 'pyprod' \$(python3 -m pip show intersystems-pyprod 2>/dev/null | awk '/^Version/{print \$2}')
intersystems_pyprod /probe/interop_example.py 2>&1
echo loader_exit=\$?
")
printf '%s\n' "$out"

echo "──────────────────────────────────────────────────────"
if printf '%s' "$out" | grep -q '#16000'; then
  echo "VERDICT: REPRODUCED (#16000 via LoadStream) — host: $(uname -s) $(uname -m)"
  echo "NOTE: loader_exit above is 0 despite the error — the loader swallows the failure."
  exit 0
else
  echo "VERDICT: NOT REPRODUCED (LoadStream OK) — host: $(uname -s) $(uname -m)"
  exit 2
fi
