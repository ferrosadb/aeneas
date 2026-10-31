#!/usr/bin/env bash
# Build Aeneas from whatever state the machine is in.
#
# Nothing here assumes a particular home directory, package manager, opam root or OCaml version.
# Every choice is discoverable first and overridable second:
#
#   AENEAS_ROOT    repository checkout          (default: the directory holding this script)
#   OPAMROOT       opam root to use             (default: an existing one, else PREFIX/.opam)
#   PREFIX         user-space install prefix    (default: $HOME/.local)
#   OCAML_VERSION  compiler for a new switch    (default: opam's default compiler)
#   GMP_PREFIX     where to build gmp if absent (default: PREFIX/gmp)
#   GMP_VERSION    gmp release to build         (default: 6.3.0)
#   CHARON_URL     charon source                (default: the upstream repository)
#   JOBS           parallelism for make        (default: number of CPUs)
#
# Each step is skipped when it is already satisfied, so re-running is safe and cheap. `--dry-run`
# prints the plan without touching anything; that is the mode to use when auditing what a fresh
# machine would do.
#
# Usage: ./bootstrap.sh [--dry-run] [--help]

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --help | -h)
      sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown argument: %s (try --help)\n' "$arg" >&2
      exit 2
      ;;
  esac
done

say() { printf '\n== %s ==\n' "$*"; }
note() { printf '   %s\n' "$*"; }
# Run a command, or print it in dry-run mode. Never hides which of the two happened.
run() {
  if [ "$DRY_RUN" = 1 ]; then
    printf '   would run: %s\n' "$*"
  else
    printf '   running: %s\n' "$*"
    "$@"
  fi
}

detect_root() {
  if [ -n "${AENEAS_ROOT:-}" ]; then
    printf '%s' "$AENEAS_ROOT"
    return
  fi
  cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}
ROOT=$(detect_root)

PREFIX=${PREFIX:-$HOME/.local}
GMP_PREFIX=${GMP_PREFIX:-$PREFIX/gmp}
GMP_VERSION=${GMP_VERSION:-6.3.0}
CHARON_URL=${CHARON_URL:-https://github.com/AeneasVerif/charon}
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 4)}
PIN_FILE=$ROOT/charon-pin

say "plan"
note "repository : $ROOT"
note "prefix     : $PREFIX"
note "opam root  : ${OPAMROOT:-(to be discovered)}"

[ -d "$ROOT/src" ] || {
  printf 'error: %s does not look like an aeneas checkout (no src/)\n' "$ROOT" >&2
  exit 1
}

# ---------------------------------------------------------------- opam binary
say "opam"
if command -v opam >/dev/null 2>&1; then
  note "found $(command -v opam)"
else
  # Static release builds exist for the four platforms that matter; anything else must supply opam.
  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) opam_arch=x86_64-linux ;;
    Linux/aarch64 | Linux/arm64) opam_arch=arm64-linux ;;
    Darwin/arm64) opam_arch=arm64-darwin ;;
    Darwin/x86_64) opam_arch=x86_64-darwin ;;
    *)
      printf 'error: no prebuilt opam for %s/%s; install opam and re-run\n' \
        "$(uname -s)" "$(uname -m)" >&2
      exit 1
      ;;
  esac
  note "no opam on PATH; fetching the $opam_arch release into $PREFIX/bin"
  if [ "$DRY_RUN" = 0 ]; then
    mkdir -p "$PREFIX/bin"
    url=$(curl -fsSL https://api.github.com/repos/ocaml/opam/releases/latest |
      python3 -c '
import json, sys
arch = sys.argv[1]
release = json.load(sys.stdin)
for asset in release["assets"]:
    if arch in asset["name"] and not asset["name"].endswith(".sha256"):
        print(asset["browser_download_url"])
        break
' "$opam_arch")
    [ -n "$url" ] || {
      printf 'error: no asset matching %s in the latest opam release\n' "$opam_arch" >&2
      exit 1
    }
    curl -fsSL -o "$PREFIX/bin/opam" "$url"
    chmod +x "$PREFIX/bin/opam"
  fi
  PATH=$PREFIX/bin:$PATH
  export PATH
fi

# ---------------------------------------------------------------- opam root
say "opam root"
pick_root() {
  # An explicit OPAMROOT wins, then a default-location root, then the user-space one. A root with
  # no switch is no more useful than no root, so only roots that actually hold one count.
  local candidate
  for candidate in "${OPAMROOT:-}" "$HOME/.opam" "$PREFIX/opam"; do
    [ -n "$candidate" ] || continue
    [ -d "$candidate" ] || continue
    if [ "$DRY_RUN" = 1 ] || [ -n "$(OPAMROOT=$candidate opam switch list --short 2>/dev/null | head -1)" ]; then
      printf '%s' "$candidate"
      return
    fi
  done
}
if [ -n "$(pick_root)" ]; then
  OPAMROOT=$(pick_root)
  note "using existing root $OPAMROOT"
else
  OPAMROOT=${OPAMROOT:-$PREFIX/opam}
  note "no usable root; will initialise $OPAMROOT"
  run mkdir -p "$OPAMROOT"
  run opam init --bare --disable-sandboxing -y --root "$OPAMROOT"
fi
export OPAMROOT
export OPAMYES=1
# Every opam call below passes --assume-depexts: it declares "the system packages are already
# here". That keeps opam from reaching for sudo on a machine that has none, without editing the
# root's configuration, so the script leaves no state behind but installed packages.

# ---------------------------------------------------------------- switch
say "switch"
switch=$(opam switch list --short 2>/dev/null | head -1 || true)
if [ -n "$switch" ]; then
  note "using switch $switch"
else
  switch=${OCAML_VERSION:-default}
  note "creating switch $switch${OCAML_VERSION:+ with OCaml $OCAML_VERSION} (compiles a compiler; the slow part)"
  if [ -n "${OCAML_VERSION:-}" ]; then
    run opam switch create "$switch" "$OCAML_VERSION" -y
  else
    run opam switch create "$switch" -y
  fi
  switch=$(opam switch list --short 2>/dev/null | head -1 || true)
  switch=${switch:-default}
fi
if [ "$DRY_RUN" = 0 ]; then
  eval "$(opam env --switch="$switch" --set-switch)"
fi

# ---------------------------------------------------------------- gmp
# zarith links against gmp. Prefer whatever the system already has; build into GMP_PREFIX only
# when there is nothing to link against, which is the no-sudo case.
say "gmp"
# Ask the C compiler that zarith will use, not a library cache: `ldconfig` lives in /sbin and is
# missing from a non-interactive PATH, which makes a machine with gmp look like a machine without
# it. A probe that compiles the header and links the library answers the real question.
probe_gmp() {
  local tmp
  tmp=$(mktemp -d)
  printf '#include <gmp.h>\nint main(void){return 0;}\n' >"$tmp/t.c"
  if "${CC:-cc}" -o "$tmp/t" "$tmp/t.c" -lgmp >/dev/null 2>&1; then
    printf system
  fi
  rm -rf "$tmp"
}
if [ "$DRY_RUN" = 1 ]; then
  note "would probe the C compiler for gmp, then fall back to $GMP_PREFIX"
  gmp_home=${GMP_PREFIX}
else
  gmp_home=$(probe_gmp)
  if [ -z "$gmp_home" ] && [ -f "$GMP_PREFIX/include/gmp.h" ]; then
    gmp_home=$GMP_PREFIX
  fi
fi
case "$gmp_home" in
  "")
    note "no gmp found; building $GMP_VERSION into $GMP_PREFIX (no sudo involved)"
    run mkdir -p "$GMP_PREFIX"
    if [ "$DRY_RUN" = 0 ]; then
      work=$PREFIX/src
      mkdir -p "$work"
      tarball=gmp-$GMP_VERSION.tar.xz
      [ -f "$work/$tarball" ] || curl -fsSL -o "$work/$tarball" \
        "https://ftp.gnu.org/gnu/gmp/$tarball"
      rm -rf "$work/gmp-$GMP_VERSION"
      tar xf "$work/$tarball" -C "$work"
      (
        cd "$work/gmp-$GMP_VERSION"
        ./configure --prefix="$GMP_PREFIX" --enable-shared --enable-cxx=no >/dev/null
        make -j"$JOBS" >/dev/null
        make install >/dev/null
      )
    fi
    gmp_home=$GMP_PREFIX
    ;;
  system) note "using the system gmp" ;;
  *) note "using gmp at $gmp_home" ;;
esac
if [ "$gmp_home" != system ]; then
  export CPATH="$gmp_home/include${CPATH:+:$CPATH}"
  export LIBRARY_PATH="$gmp_home/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
  # Runtime path matters on macOS (no ldconfig) and for anything linking a shared build.
  if [ "$(uname -s)" = Darwin ]; then
    export DYLD_LIBRARY_PATH="$gmp_home/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
  else
    export LD_LIBRARY_PATH="$gmp_home/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  fi
fi

# ---------------------------------------------------------------- aeneas deps
say "aeneas dependencies"
run opam install "$ROOT/src/aeneas.opam" --deps-only -y --assume-depexts

say "dune and odoc"
# odoc is not in charon-opam's dependency list, but charon-ml's `make` runs `dune build @doc`.
# Discovered by running it: without odoc the build stops with "Program odoc not found".
odoc_version=$(opam exec --switch="$switch" -- odoc --version 2>/dev/null || true)
if [ -z "$odoc_version" ]; then
  note "no odoc in switch $switch; installing it (charon-ml builds @doc)"
  run opam install odoc -y --assume-depexts
else
  note "odoc $odoc_version"
fi
# Ask the switch rather than PATH: in a dry run the environment is not activated, and a fresh
# shell has not run `eval $(opam env)` either.
dune_version=$(opam exec --switch="$switch" -- dune --version 2>/dev/null || true)
if [ -z "$dune_version" ]; then
  note "no dune in switch $switch; installing it"
  run opam install dune -y --assume-depexts
else
  note "dune $dune_version"
fi

# ---------------------------------------------------------------- charon
say "charon"
if [ -f "$PIN_FILE" ]; then
  pin=$(tail -1 "$PIN_FILE" | tr -d '[:space:]')
  note "pin $pin"
else
  pin=""
  note "no charon-pin file; staying on whatever the checkout already has"
fi
if [ -d "$ROOT/charon/.git" ]; then
  note "existing checkout at $ROOT/charon"
  [ -z "$pin" ] || run git -C "$ROOT/charon" checkout -q "$pin"
else
  note "cloning $CHARON_URL"
  if [ "$DRY_RUN" = 0 ]; then
    rm -rf "$ROOT/charon"
    git clone --recurse-submodules "$CHARON_URL" "$ROOT/charon"
    [ -z "$pin" ] || git -C "$ROOT/charon" fetch -q origin "$pin" 2>/dev/null || true
    [ -z "$pin" ] || git -C "$ROOT/charon" checkout -q "$pin"
  fi
fi
if [ -f "$ROOT/charon/charon.opam" ]; then
  # charon's opam file depends on sibling packages that live in the same checkout and exist in no
  # repository (`name_matcher_parser` today). They have to be installed as path packages first, or
  # dependency resolution fails with "unknown package".
  for extra in "$ROOT"/charon/*.opam; do
    [ -e "$extra" ] || continue
    if [ "$(basename "$extra")" != charon.opam ]; then
      run opam install "$extra" -y --assume-depexts
    fi
  done
  run opam install "$ROOT/charon/charon.opam" --deps-only -y --assume-depexts
fi
# `make` is the documented entry point; `make build` is the fallback for revisions that only
# declare the latter. Pin cargo's target directory to the one charon's Makefile copies from: a
# machine-wide cargo config can redirect target/, and then `make` fails at the copy step with
# "cannot stat charon/target/release/charon" even though the build itself succeeded.
# The path is the *inner* crate's target directory: charon's Makefile copies from
# `charon/target/release/` while sitting in charon/, i.e. from charon/charon/target/.
export CARGO_TARGET_DIR=$ROOT/charon/charon/target
run make -C "$ROOT/charon" -j"$JOBS"

# ---------------------------------------------------------------- build
say "aeneas"
run dune build --root "$ROOT/src"
binary=$ROOT/src/_build/default/main.exe
if [ "$DRY_RUN" = 0 ]; then
  if [ -x "$binary" ]; then
    note "built $binary"
  else
    printf 'error: build finished without producing %s\n' "$binary" >&2
    exit 1
  fi
fi
