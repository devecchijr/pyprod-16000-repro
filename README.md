# pyprod #16000 — reproducible test case

One-command reproduction of [intersystems/pyprod#11](https://github.com/intersystems/pyprod/issues/11):
`ERROR #16000 "Internal compiler error"` when the pyprod loader writes the
generated class through `%SYSTEM.OBJ.LoadStream`, while the **same generated
class compiles cleanly** when loaded from a file (`--manual -o` +
`$SYSTEM.OBJ.Load`).

## TL;DR

```bash
./repro.sh
```

Spins up a **disposable** IRIS container replicating the pyprod CI job (same
`intersystems/iris-community:2026.1` image, same `merge.cpf` — ENSEMBLE
namespace with Interop, `%Service_CallIn`, `superuser/SYS`), runs the minimal
loader from the issue, prints the full error signature and a verdict, then
removes everything. Nothing on the host is touched. Requires only Docker.

```
VERDICT: REPRODUCED (#16000 via LoadStream)      → exit 0
VERDICT: NOT REPRODUCED (LoadStream OK)          → exit 2
```

## Why this repo exists

The pyprod CI (same images, same prep) passes cleanly, so the natural question
was *what's different*. We eliminated the candidate variables one at a time —
each dimension is a flag of `repro.sh`:

```bash
./repro.sh [arch] [source] [user] [startup]
#           arm64|amd64  pypi|main  root|irisowner  entrypoint|cistart
```

| Variable | Values tested | Result on Docker Desktop for macOS |
|---|---|---|
| Architecture | native **arm64**, emulated **amd64** | `#16000` on **both** |
| pyprod build | **PyPI 0.2.0**, **`main`** tarball (CI builds from checkout) | `#16000` on **both** |
| Process user | **root** (CI uses `--user 0:0`), **irisowner** | `#16000` on **both** |
| IRIS startup | image **entrypoint** (iris-main), **cistart** (bare `iris start` as irisowner, like CI) | `#16000` on **both** |
| Python | image system 3.12, venv, standalone CPython 3.12 (uv) | `#16000` on **all three** |
| Image/edition | `intersystems/iris-community:2026.1` (CI image), `intersystemsdc/iris-community:2025.3`, `irepo .../iris:2025.1`, `irepo .../iris:2026.1` | `#16000` on **all** (so not IRIS-for-Health vs IRIS, not irepo vs regular) |

Every cell fails on **Docker Desktop for macOS** (LinuxKit VM — the emulated
amd64 runs through it as well). The pyprod CI passes on **native Linux
runners**. After eliminating everything above, the host virtualization layer
is the remaining differential.

**The decisive test:** run `./repro.sh` on a native Linux box. If it prints
`NOT REPRODUCED`, the trigger is isolated to the Docker Desktop/macOS layer —
which still matters: that is the daily environment of every Mac-based
developer using pyprod.

## Proof logs

`logs/` contains the captured output of each matrix cell run on this host
(Docker Desktop for macOS, Apple Silicon), including the full error signature:

```
ERROR #16008: Unable to save text for 'Example.EchoBP.cls', $compile language '128',
$compile flags '16777216', $compile returned '-33928',
$zu(56,2)=$Id: //iris/2026.1.0/kernel/common/src/sqio.c#1 $ 3658 0,
filename '/usr/irissys/mgr/Temp/<random>.xml', # of source lines '51',
beginning of source:
  > ERROR #16000: Line:0 Offset:0 Error 'Internal compiler error'
```

Observations that may help locate the fault:

- The temp file is written with an **`.xml` extension but loaded "as udl"**
  (`Loading file /usr/irissys/mgr/Temp/….xml as udl`).
- `beginning of source:` is **empty** in the #16008 message and the error comes
  from `sqio.c` (file I/O) — as if the compiler cannot read back the temp file
  it was just handed.
- `loader_exit=0` in every failing log: `intersystems_pyprod` prints the error
  but **exits 0**, so a CI step (`bash -e`) does not fail on it.

## Repository layout

```
repro.sh                one-command reproduction (disposable container, verdict, cleanup)
run-matrix.sh           runs the evidence matrix and captures logs/ per cell
assets/merge.cpf        CI-identical instance prep (ENSEMBLE + Interop + CallIn)
assets/interop_example.py  the 8-line component from the issue
logs/                   proof logs per matrix cell + SUMMARY.txt
```

## Provenance

Found during agent-driven development pilots (Claude Code / Codex / Antigravity
operating IRIS via MCP) on an IRIS application dev-kit; every finding was then
reproduced manually in a controlled environment before being reported. No
credentials beyond the CI's own public `merge.cpf` defaults, no license
content, and no private source are used anywhere in this repo.
