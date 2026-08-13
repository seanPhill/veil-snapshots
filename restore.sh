#!/usr/bin/env bash
# Downloads the latest Veil snapshot release, verifies every file, and unpacks
# it into the Veil data directory. Run it with the wallet closed.
#
# Usage: restore.sh [--testnet] [--datadir <path>] [--tag <tag>] [--repo <o/r>]
#                   [--check] [--yes]
#   --testnet  restore testnet instead of mainnet
#   --datadir  target data directory (default: the platform's standard one)
#   --tag      restore a specific release instead of the latest
#   --repo     pull from a mirror instead of the default publisher
#   --check    verify tools and show the plan, download nothing big
#   --yes      no prompts, assume yes (for scripted use)

set -euo pipefail

# bumped whenever this script changes in a way users should pick up. The run
# compares it against the published copy and says so if yours is behind.
SCRIPT_VERSION=2

REPO="ohcee/veil-snapshots"
# the version check always asks the default publisher, so a mirror that lags
# behind cannot tell you your script is current when it is not
HOME_REPO="$REPO"

DATADIR=""
TAG=""
CHECK=0
YES=0
TESTNET=0
while [ $# -gt 0 ]; do
    case "$1" in
        --testnet) TESTNET=1; shift ;;
        --datadir) DATADIR="$2"; shift 2 ;;
        --tag)     TAG="$2"; shift 2 ;;
        --repo)    REPO="$2"; shift 2 ;;
        --check)   CHECK=1; shift ;;
        --yes)     YES=1; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done
case "$REPO" in
    */*) : ;;
    *) echo "ERROR: --repo wants owner/name, got '$REPO'" >&2; exit 2 ;;
esac

if [ -z "$DATADIR" ]; then
    if [ "$(uname)" = "Darwin" ]; then
        DATADIR="$HOME/Library/Application Support/Veil"
    else
        DATADIR="$HOME/.veil"
    fi
fi

# testnet chain data lives in a subfolder, and its releases are never flagged
# "latest" on GitHub, so the newest testnet tag has to be looked up by name
if [ "$TESTNET" = 1 ]; then
    CHAIN_LABEL=testnet
    TARGET="$DATADIR/testnet4"
else
    CHAIN_LABEL=mainnet
    TARGET="$DATADIR"
fi

if [ -z "$TAG" ] && [ "$TESTNET" = 1 ]; then
    TAG=$(curl -fsSL --http1.1 "https://api.github.com/repos/$REPO/releases?per_page=100" 2>/dev/null \
        | grep -o '"tag_name": *"testnet-[^"]*"' | head -1 \
        | sed 's/.*"\(testnet-[^"]*\)"/\1/') || true
    [ -n "$TAG" ] || { echo "ERROR: no testnet release published yet in $REPO" >&2; exit 1; }
fi

if [ -n "$TAG" ]; then
    BASE="https://github.com/$REPO/releases/download/$TAG"
else
    BASE="https://github.com/$REPO/releases/latest/download"
fi
WORK="veil-snapshot-work"

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

# http 1.1 on purpose: some networks kill long http/2 streams (curl error 92),
# and every retry resumes where the last attempt stopped. aria2 is used when
# it is installed because it handles flaky links better than anything else.
# pass "quiet" as the third argument for small files, so the progress
# machinery does not drown out the actual messages
dl() {
    local url="$1" out="$2" quiet="${3:-}" attempt=1
    if command -v aria2c >/dev/null 2>&1; then
        if [ "$quiet" = quiet ]; then
            aria2c --continue=true --max-tries=5 --retry-wait=5 --timeout=60 \
                --quiet=true --dir="$(dirname "$out")" --out="$(basename "$out")" "$url"
            return $?
        fi
        aria2c --continue=true --max-tries=5 --retry-wait=5 --timeout=60 \
            --max-connection-per-server=4 --split=4 --min-split-size=20M \
            --console-log-level=warn --summary-interval=15 \
            --dir="$(dirname "$out")" --out="$(basename "$out")" "$url"
        return $?
    fi
    if command -v curl >/dev/null 2>&1; then
        local bar=--progress-bar
        [ "$quiet" = quiet ] && bar=-s
        while :; do
            curl -fL --http1.1 --retry 3 $bar -C - -o "$out" "$url" && return 0
            attempt=$((attempt + 1))
            [ "$attempt" -gt 5 ] && return 1
            echo "download interrupted, resuming (attempt $attempt of 5)" >&2
            sleep 5
        done
    fi
    wget -c --tries=5 -O "$out" "$url"
}

# a stale copy is easy to end up with, since this script does not update itself
# and people keep the one they downloaded. Never fatal: no network, no warning.
check_version() {
    local body latest="" line
    body=$(curl -fsSL --http1.1 --max-time 10 \
        "https://raw.githubusercontent.com/$HOME_REPO/main/restore.sh" 2>/dev/null) || return 0
    # parsed without a pipe on purpose: an early-exiting grep would SIGPIPE
    # curl, and pipefail would turn that into a silent failure
    while IFS= read -r line; do
        case "$line" in
            SCRIPT_VERSION=*)
                latest=${line#SCRIPT_VERSION=}
                latest=${latest%%[!0-9]*}
                break ;;
        esac
    done <<EOF
$body
EOF
    case "$latest" in *[!0-9]*|'') return 0 ;; esac
    if [ "$latest" -gt "$SCRIPT_VERSION" ]; then
        echo
        say "heads up: you are running restore.sh v$SCRIPT_VERSION, v$latest is published."
        say "this script does not update itself. To get the newest one:"
        say "  curl -fsSL -o restore.sh https://raw.githubusercontent.com/$HOME_REPO/main/restore.sh"
        say "continuing with your copy in 5 seconds, Ctrl-C to stop and update"
        echo
        sleep 5
    fi
}

confirm() {
    [ "$YES" = 1 ] && return 0
    [ -t 0 ] || die "not running in a terminal, rerun with --yes to skip prompts"
    printf "%s [y/N] " "$1"
    read -r ans
    case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ---- preflight ----------------------------------------------------------

command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || die "need curl or wget installed"
command -v tar >/dev/null 2>&1 || die "need tar installed"
if ! command -v zstd >/dev/null 2>&1; then
    if [ "$(uname)" = "Darwin" ]; then
        die "zstd is not installed. Install it with: brew install zstd"
    else
        die "zstd is not installed. Install it with your package manager, e.g.: sudo apt install zstd"
    fi
fi

WALLET_RUNNING=0
if pgrep -x veild >/dev/null 2>&1 || pgrep -x veil-qt >/dev/null 2>&1 \
    || pgrep -x Veil >/dev/null 2>&1; then
    WALLET_RUNNING=1
fi
if [ "$WALLET_RUNNING" = 1 ] && [ "$CHECK" = 0 ]; then
    die "a Veil wallet or node is running, close it completely first"
fi

check_version

mkdir -p "$WORK"
say "fetching the release file list"
rm -f "$WORK/SHA256SUMS" "$WORK/manifest.json"
dl "$BASE/SHA256SUMS" "$WORK/SHA256SUMS" quiet
dl "$BASE/manifest.json" "$WORK/manifest.json" quiet

HEIGHT=$(grep -o '"height": *[0-9]*' "$WORK/manifest.json" | head -1 | grep -o '[0-9]*' || echo "unknown")
COMPRESSED=$(grep -o '"compressed_bytes": *[0-9]*' "$WORK/manifest.json" | head -1 | grep -o '[0-9]*' || echo 0)
PARTS=$(awk '/\.tar\.zst\.part-/ {print $2}' "$WORK/SHA256SUMS")
PART_COUNT=$(echo "$PARTS" | wc -l | tr -d ' ')
[ -n "$PARTS" ] || die "could not read the part list from SHA256SUMS"

COMP_GB=$(echo "$COMPRESSED" | awk '{printf "%.1f", $1 / 1073741824}')
NEED_KB=$(echo "$COMPRESSED" | awk '{printf "%d", $1 * 2.2 / 1024}')
AVAIL_KB=$(df -k "$WORK" | tail -1 | awk '{print $4}')

say "$CHAIN_LABEL snapshot height $HEIGHT, ${COMP_GB}GB to download in $PART_COUNT parts"
say "target directory: $TARGET"
if command -v aria2c >/dev/null 2>&1; then
    say "using aria2 for the download"
else
    say "aria2 is not installed, falling back to curl (slower, and it gives up"
    say "more easily on a bad connection). Stop now and install it if you can:"
    if [ "$(uname)" = "Darwin" ]; then
        say "  brew install aria2"
    else
        say "  sudo apt install aria2"
    fi
    say "then rerun this script. Anything already downloaded is kept."
fi

if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
    echo "WARNING: this needs roughly $((NEED_KB / 1048576))GB free during restore, you have $((AVAIL_KB / 1048576))GB" >&2
    [ "$CHECK" = 1 ] || confirm "continue anyway?" || exit 1
fi

if [ "$CHECK" = 1 ]; then
    [ "$WALLET_RUNNING" = 1 ] && echo "WARNING: a wallet is running, a real restore would refuse to start" >&2
    say "check complete, everything needed is in place"
    exit 0
fi

# ---- download and verify ------------------------------------------------

for f in $PARTS; do
    want=$(awk -v f="$f" '$2 == f {print $1}' "$WORK/SHA256SUMS")
    if [ -f "$WORK/$f" ] && [ "$(sha256 "$WORK/$f")" = "$want" ]; then
        say "$f already downloaded and verified, skipping"
        continue
    fi
    say "downloading $f"
    dl "$BASE/$f" "$WORK/$f" || true
    [ -f "$WORK/$f" ] || die "$f never arrived, rerun this script to try again"
    if [ "$(sha256 "$WORK/$f")" != "$want" ]; then
        die "$f did not complete, rerun this script and it resumes where it left off"
    fi
done

say "verifying checksums"
cd "$WORK"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
else
    shasum -a 256 -c SHA256SUMS
fi
cd ..

# ---- unpack -------------------------------------------------------------

mkdir -p "$TARGET"
EXISTING=""
for d in blocks chainstate indexes zerocoin; do
    [ -d "$TARGET/$d" ] && EXISTING="$EXISTING $d"
done
if [ -n "$EXISTING" ]; then
    echo "the $CHAIN_LABEL directory already has:$EXISTING"
    confirm "replace them with the snapshot? (wallets and settings are untouched)" \
        || die "stopped, nothing was changed"
    for d in $EXISTING; do
        rm -rf "${TARGET:?}/$d"
    done
fi

say "unpacking into $TARGET (this takes a few minutes)"
# snapshots built on a mac carry apple xattrs that GNU tar does not know, and
# it warns once per file about them. The files extract fine, so hush it.
TAR_OPTS=""
tar --version 2>&1 | grep -qi "GNU tar" && TAR_OPTS="--warning=no-unknown-keyword"
# shellcheck disable=SC2086
cat "$WORK"/*.tar.zst.part-* | zstd -d | tar $TAR_OPTS -x -C "$TARGET"

say "cleaning up downloaded files"
rm -rf "$WORK"

if [ "$TESTNET" = 1 ]; then
    say "done. Start your wallet with -testnet and it will sync the rest from the network."
else
    say "done. Start your Veil wallet, it will sync the remaining blocks from the network."
fi
