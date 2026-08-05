#!/usr/bin/env bash
#
# Builds the tmux versions R3.6 names — 3.0, 3.2a, 3.3a, 3.4, 3.5 — so fixtures can be captured
# from each of them.
#
# This is **not** a CI step, and running it in CI would be worse than not having it. Fixtures are
# *inputs* to the codec tests: their value is that they are frozen records of what a given tmux
# actually said, so a parser regression shows up as a disagreement with the record. Regenerate them
# on every run and the test asserts "the parser agrees with whatever tmux just said", which is true
# by construction and catches nothing. The inputs here are pinned release tarballs, so a rebuild
# produces byte-identical output forever; the cost would be minutes per push for no signal.
#
# What this script is for is **provenance**. Without it the fixtures are one person's word about
# what they once saw. With it anyone can rebuild, recapture, and diff.
#
#   Scripts/build-tmux-matrix.sh              # build all of them
#   Scripts/build-tmux-matrix.sh 3.0 3.5      # or just some
#
# Binaries land in .tmux-matrix/bin/<version>/tmux and are gitignored: they are a means, not an
# artifact. The artifact is Tests/tetmuxCoreTests/Fixtures, which Scripts/capture-fixtures.py writes.
#
# Each one is installed under the plain name `tmux`, in a directory of its own, rather than as
# `tmux-3.5`. tmux names a window after the command running in it, so argv[0] ends up *inside the
# fixtures* — `%window-renamed @0 tmux-3.5` — which would make every capture a record of what this
# script happened to call the file rather than of the version.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/.tmux-matrix"
BIN="$WORK/bin"

# Pinned, with checksums, because "download whatever is at this URL and run it" is not provenance.
# A mismatch is fatal rather than a warning: a fixture captured from an unverified binary is worth
# less than no fixture, since it would be believed.
VERSIONS=(3.0 3.2a 3.3a 3.4 3.5)
sha_for() {
    case "$1" in
        3.0)  echo 9edcd78df80962ee2e6471a8f647602be5ded62bb41c574172bb3dc3d0b9b4b4 ;;
        3.2a) echo 551553a4f82beaa8dadc9256800bcc284d7c000081e47aa6ecbb6ff36eacd05f ;;
        3.3a) echo e4fd347843bd0772c4f48d6dde625b0b109b7a380ff15db21e97c11a4dcdf93f ;;
        3.4)  echo 551ab8dea0bf505c0ad6b7bb35ef567cdde0ccb84357df142c254f35a23e19aa ;;
        3.5)  echo 2fe01942e7e7d93f524a22f2c883822c06bc258a4d61dba4b407353d7081950f ;;
        *)    return 1 ;;
    esac
}

wanted=("$@")
if [ ${#wanted[@]} -eq 0 ]; then
    wanted=("${VERSIONS[@]}")
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "error: needs Homebrew for libevent, ncurses and utf8proc" >&2
    exit 1
fi

for pkg in libevent ncurses utf8proc; do
    if ! brew --prefix "$pkg" >/dev/null 2>&1; then
        echo "error: missing dependency '$pkg' — brew install $pkg" >&2
        exit 1
    fi
done

# utf8proc deliberately, not --disable-utf8proc, even though the build succeeds without it: it is
# what decides how wide tmux thinks a character is, so a capture made without it would disagree with
# every real installation about layouts and output containing anything outside Latin-1. Homebrew's
# own tmux links it, which is the installation these fixtures are supposed to describe.
export PKG_CONFIG_PATH="$(brew --prefix libevent)/lib/pkgconfig:$(brew --prefix ncurses)/lib/pkgconfig:$(brew --prefix utf8proc)/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
# …and the include/library paths as well, because the older releases do not look for utf8proc
# through pkg-config at all — 3.0's configure does a plain header check and fails with
# "utf8proc not found" however complete PKG_CONFIG_PATH is.
export CPPFLAGS="-I$(brew --prefix utf8proc)/include -I$(brew --prefix ncurses)/include${CPPFLAGS:+ $CPPFLAGS}"
export LDFLAGS="-L$(brew --prefix utf8proc)/lib -L$(brew --prefix ncurses)/lib${LDFLAGS:+ $LDFLAGS}"

mkdir -p "$WORK/src" "$BIN"

for version in "${wanted[@]}"; do
    if ! expected="$(sha_for "$version")"; then
        echo "error: unknown version '$version' (have: ${VERSIONS[*]})" >&2
        exit 1
    fi

    target="$BIN/$version/tmux"
    if [ -x "$target" ]; then
        echo "have  tmux $version  ($("$target" -V))"
        continue
    fi

    tarball="$WORK/src/tmux-$version.tar.gz"
    if [ ! -f "$tarball" ]; then
        echo "fetch tmux $version"
        curl -fsSL --max-time 300 -o "$tarball" \
            "https://github.com/tmux/tmux/releases/download/$version/tmux-$version.tar.gz"
    fi

    actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    if [ "$actual" != "$expected" ]; then
        echo "error: checksum mismatch for tmux $version" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        rm -f "$tarball"
        exit 1
    fi

    echo "build tmux $version"
    src="$WORK/src/tmux-$version"
    rm -rf "$src"
    tar xzf "$tarball" -C "$WORK/src"

    (
        cd "$src"
        # 3.3 and later require the flag to be explicit and refuse to guess.
        if ./configure --help 2>/dev/null | grep -q enable-utf8proc; then
            ./configure --enable-utf8proc >build.log 2>&1
        else
            ./configure >build.log 2>&1
        fi
        make -j"$(sysctl -n hw.ncpu)" >>build.log 2>&1
    ) || {
        echo "error: build failed for tmux $version — see $src/build.log" >&2
        exit 1
    }

    mkdir -p "$(dirname "$target")"
    cp "$src/tmux" "$target"
    echo "  -> $target ($("$target" -V))"
done

echo
echo "built into $BIN:"
for version in "${wanted[@]}"; do
    printf '  %-6s %s\n' "$version" "$("$BIN/$version/tmux" -V 2>/dev/null || echo 'missing')"
done
