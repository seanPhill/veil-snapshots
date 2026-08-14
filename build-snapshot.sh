#!/usr/bin/env bash
# Builds a Veil snapshot from a local synced node and publishes it as a
# GitHub release. See README.md for restore and verification steps.
#
# Config comes from environment variables, all optional on the standard setup:
#   VEIL_BIN     dir holding veild and veil-cli    (default: ~/dev/veil-bin)
#   DATADIR      veil data directory               (default: platform default)
#   WORKDIR     scratch space for the build        (default: work/ next to script)
#   REPO         github repo that hosts releases   (default: ohcee/veil-snapshots)
#   ZSTD_LEVEL   compression level                 (default: 10)
#   PART_SIZE    split size, must stay under 2GiB  (default: 1900m)
#   STOP_TIMEOUT seconds to wait for shutdown      (default: 600)
#   START_TIMEOUT seconds to wait for RPC on boot  (default: 900)
#   START_CMD    custom node start command         (default: veild -daemon)
#   STOP_CMD     custom node stop command          (default: veil-cli stop)
#   GPG_KEY      key id to sign SHA256SUMS with    (default: unset, no signing)
#   MIN_AGE_DAYS skip build if latest release is   (default: 60)
#                younger than this many days
#
# Several builders can share the same schedule: the age check means whoever
# fires first each quarter publishes and everyone else's run exits clean.
# Mainnet and testnet are tracked separately, so one never blocks the other.
#
# Usage: build-snapshot.sh [--testnet] [--dry-run] [--no-publish] [--force] [--keep]
#   --testnet     snapshot testnet instead of mainnet
#   --dry-run     check environment and node, print capture metadata, change nothing
#   --no-publish  build the archive locally but skip the github release
#   --force       build even when a recent release already exists
#   --keep        leave the built parts on disk after uploading, for seeding
#                 a torrent or copying to a mirror
#
# On a node managed by systemd, point the stop and start commands at the unit:
#   STOP_CMD="systemctl stop veild" START_CMD="systemctl start veild" ./build-snapshot.sh --testnet

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

VEIL_BIN="${VEIL_BIN:-$HOME/dev/veil-bin}"
if [ "$(uname)" = "Darwin" ]; then
    DEFAULT_DATADIR="$HOME/Library/Application Support/Veil"
else
    DEFAULT_DATADIR="$HOME/.veil"
fi
DATADIR="${DATADIR:-$DEFAULT_DATADIR}"
WORKDIR="${WORKDIR:-$SCRIPT_DIR/work}"
REPO="${REPO:-ohcee/veil-snapshots}"
ZSTD_LEVEL="${ZSTD_LEVEL:-10}"
PART_SIZE="${PART_SIZE:-1900m}"
STOP_TIMEOUT="${STOP_TIMEOUT:-600}"
START_TIMEOUT="${START_TIMEOUT:-900}"
START_CMD="${START_CMD:-}"
STOP_CMD="${STOP_CMD:-}"
GPG_KEY="${GPG_KEY:-}"
MIN_AGE_DAYS="${MIN_AGE_DAYS:-60}"

CLI="$VEIL_BIN/veil-cli"
VEILD="$VEIL_BIN/veild"
REQUIRED_FOLDERS="blocks chainstate zerocoin"
OPTIONAL_FOLDERS="indexes"

DRY_RUN=0
PUBLISH=1
FORCE=0
TESTNET=0
KEEP=0
for arg in "$@"; do
    case "$arg" in
        --testnet)    TESTNET=1 ;;
        --dry-run)    DRY_RUN=1 ;;
        --no-publish) PUBLISH=0 ;;
        --force)      FORCE=1 ;;
        --keep)       KEEP=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

# testnet lives in a subfolder of the datadir and answers to a different
# chain name, everything else about the build is identical
if [ "$TESTNET" = 1 ]; then
    CHAIN_LABEL=testnet
    WANT_CHAIN=test
    NET_ARG=-testnet
    CHAIN_DIR="$DATADIR/testnet4"
else
    CHAIN_LABEL=mainnet
    WANT_CHAIN=main
    NET_ARG=
    CHAIN_DIR="$DATADIR"
fi

NODE_STOPPED=0
NET_OFF=0

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC2086
rpc() { "$CLI" -datadir="$DATADIR" $NET_ARG "$@"; }

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

iso_to_epoch() {
    date -j -f "%Y-%m-%dT%H:%M:%SZ" "$1" +%s 2>/dev/null \
        || date -d "$1" +%s 2>/dev/null \
        || echo 0
}

start_node() {
    if [ -n "$START_CMD" ]; then
        sh -c "$START_CMD"
    else
        # shellcheck disable=SC2086
        "$VEILD" -datadir="$DATADIR" $NET_ARG -daemon
    fi
    # the start command returned, so the node is running again and the exit
    # trap must not try to start it a second time. Clear the flag here rather
    # than after the wait below, which can bail out early on a slow loader.
    NODE_STOPPED=0

    # a big chain takes a while to load its block index before RPC answers:
    # about 40s for 28GB on an M4, over 3 minutes on a modest VPS
    local waited=0
    while ! rpc getblockcount >/dev/null 2>&1; do
        waited=$((waited + 3))
        if [ "$waited" -ge "$START_TIMEOUT" ]; then
            echo "WARNING: node has not answered RPC after ${START_TIMEOUT}s." >&2
            echo "         It may still be loading, but check it: the upload continues either way." >&2
            return 0
        fi
        if [ $((waited % 60)) = 0 ]; then
            log "still waiting for the node to finish loading (${waited}s)"
        fi
        sleep 3
    done
    [ "$waited" -gt 0 ] && log "node answered RPC after ${waited}s"
    return 0
}

cleanup() {
    local status=$?
    if [ "$NODE_STOPPED" = 1 ]; then
        echo "build failed with node stopped, restarting it" >&2
        start_node || echo "COULD NOT RESTART NODE, run veild manually" >&2
    elif [ "$NET_OFF" = 1 ]; then
        rpc setnetworkactive true >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup EXIT

stop_node() {
    local pid=""
    [ -f "$CHAIN_DIR/veild.pid" ] && pid=$(cat "$CHAIN_DIR/veild.pid" 2>/dev/null || true)
    NODE_STOPPED=1
    NET_OFF=0
    if [ -n "$STOP_CMD" ]; then
        sh -c "$STOP_CMD"
    else
        rpc stop >/dev/null
    fi
    local waited=0
    while :; do
        if [ -n "$pid" ]; then
            kill -0 "$pid" 2>/dev/null || break
        else
            pgrep -x veild >/dev/null 2>&1 || break
        fi
        waited=$((waited + 2))
        [ "$waited" -ge "$STOP_TIMEOUT" ] && die "node did not stop within ${STOP_TIMEOUT}s"
        sleep 2
    done
}

# ---- preflight ----------------------------------------------------------

for tool in zstd jq tar split; do
    command -v "$tool" >/dev/null 2>&1 || die "missing tool: $tool"
done
[ -x "$CLI" ] || die "veil-cli not found at $CLI (set VEIL_BIN)"
[ -x "$VEILD" ] || die "veild not found at $VEILD (set VEIL_BIN)"
[ -d "$DATADIR" ] || die "datadir not found: $DATADIR"

if pgrep -x veil-qt >/dev/null 2>&1; then
    die "veil-qt is running and holds the datadir, close the GUI wallet first"
fi

[ -d "$CHAIN_DIR" ] || die "$CHAIN_LABEL directory not found: $CHAIN_DIR"

FOLDERS=""
for f in $REQUIRED_FOLDERS; do
    [ -d "$CHAIN_DIR/$f" ] || die "required folder missing from $CHAIN_LABEL dir: $f"
    FOLDERS="$FOLDERS $f"
done
for f in $OPTIONAL_FOLDERS; do
    if [ -d "$CHAIN_DIR/$f" ]; then
        FOLDERS="$FOLDERS $f"
    else
        log "note: optional folder $f not present, skipping"
    fi
done

if [ "$PUBLISH" = 1 ] && [ "$DRY_RUN" = 0 ]; then
    command -v gh >/dev/null 2>&1 || die "gh cli not installed (or use --no-publish)"
    gh auth status >/dev/null 2>&1 || die "gh not authenticated, run: gh auth login"
fi
if [ "$DRY_RUN" = 1 ] && ! gh auth status >/dev/null 2>&1; then
    log "note: gh not authenticated yet, publishing would fail"
fi

if [ "$PUBLISH" = 1 ] && [ "$FORCE" = 0 ] && gh auth status >/dev/null 2>&1; then
    # only this chain's releases count, so mainnet and testnet never block each other
    latest=$(gh release list -R "$REPO" --limit 100 --json tagName,publishedAt \
        -q "[.[] | select(.tagName | startswith(\"${CHAIN_LABEL}-\"))] | .[0].publishedAt" 2>/dev/null || true)
    if [ -n "$latest" ] && [ "$latest" != "null" ]; then
        age_days=$(( ($(date +%s) - $(iso_to_epoch "$latest")) / 86400 ))
        if [ "$age_days" -lt "$MIN_AGE_DAYS" ]; then
            if [ "$DRY_RUN" = 1 ]; then
                log "note: latest $CHAIN_LABEL release is ${age_days}d old, a real run would stop here (MIN_AGE_DAYS=$MIN_AGE_DAYS)"
            else
                log "latest $CHAIN_LABEL release is ${age_days}d old, under MIN_AGE_DAYS=$MIN_AGE_DAYS, nothing to do (--force overrides)"
                exit 0
            fi
        else
            log "latest $CHAIN_LABEL release is ${age_days}d old, building a fresh one"
        fi
    fi
fi

rpc getblockcount >/dev/null 2>&1 || die "node not reachable via RPC at $DATADIR"

CHAININFO=$(rpc getblockchaininfo)
CHAIN=$(echo "$CHAININFO" | jq -r .chain)
[ "$CHAIN" = "$WANT_CHAIN" ] \
    || die "node reports chain '$CHAIN' but this run targets $CHAIN_LABEL ('$WANT_CHAIN')"
BLOCKS=$(echo "$CHAININFO" | jq -r .blocks)
HEADERS=$(echo "$CHAININFO" | jq -r .headers)
PROGRESS=$(echo "$CHAININFO" | jq -r .verificationprogress)
[ "$BLOCKS" = "$HEADERS" ] || die "node not synced: $BLOCKS of $HEADERS blocks"
SYNCED=$(echo "$PROGRESS" | awk '{print ($1 > 0.9999) ? "yes" : "no"}')
[ "$SYNCED" = "yes" ] || die "node not synced: verificationprogress $PROGRESS"

DATA_KB=0
for f in $FOLDERS; do
    kb=$(du -sk "$CHAIN_DIR/$f" | awk '{print $1}')
    DATA_KB=$((DATA_KB + kb))
done
mkdir -p "$WORKDIR"
AVAIL_KB=$(df -k "$WORKDIR" | tail -1 | awk '{print $4}')
NEED_KB=$((DATA_KB + 1048576))
if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
    die "not enough disk in $WORKDIR: need ~$((NEED_KB / 1048576))GB, have $((AVAIL_KB / 1048576))GB"
fi
log "preflight ok: $CHAIN_LABEL synced at $BLOCKS, data $((DATA_KB / 1048576))GB, folders:$FOLDERS"

# ---- capture metadata ---------------------------------------------------

if [ "$DRY_RUN" = 0 ]; then
    rpc setnetworkactive false >/dev/null
    NET_OFF=1
    sleep 2
fi

HEIGHT=$(rpc getblockcount)
BESTHASH=$(rpc getbestblockhash)
SUBVERSION=$(rpc getnetworkinfo | jq -r .subversion)
TXOUTSET=$(rpc gettxoutsetinfo 2>/dev/null) || TXOUTSET='{}'
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

NAME="veil-${CHAIN_LABEL}-h${HEIGHT}"
TAG="${CHAIN_LABEL}-h${HEIGHT}"

if [ "$DRY_RUN" = 1 ]; then
    log "dry run: would capture $NAME"
    jq -n --arg name "$NAME" --arg created "$CREATED" --argjson height "$HEIGHT" \
        --arg bestblockhash "$BESTHASH" --arg subversion "$SUBVERSION" \
        --argjson txoutsetinfo "$TXOUTSET" \
        '{name: $name, created: $created, height: $height, bestblockhash: $bestblockhash, node: $subversion, txoutsetinfo: $txoutsetinfo}'
    log "dry run complete, nothing changed (network toggle skipped)"
    exit 0
fi

# ---- archive ------------------------------------------------------------

OUT="$WORKDIR/$NAME"
rm -rf "$OUT"
mkdir -p "$OUT"

log "stopping node for archive (tip frozen at $HEIGHT)"
stop_node
log "node stopped, compressing $((DATA_KB / 1048576))GB (zstd level $ZSTD_LEVEL, this takes a while)"

# macOS tar records apple xattrs by default, which makes GNU tar on Linux
# print a warning for every single file on extract. Leave them out.
TAR_CREATE_OPTS=""
if tar --version 2>&1 | grep -qi bsdtar; then
    TAR_CREATE_OPTS="--no-mac-metadata --no-xattrs"
elif tar --version 2>&1 | grep -qi "GNU tar"; then
    TAR_CREATE_OPTS="--no-xattrs"
fi

# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar $TAR_CREATE_OPTS -C "$CHAIN_DIR" -cf - $FOLDERS \
    | zstd -T0 "-$ZSTD_LEVEL" -q \
    | split -b "$PART_SIZE" - "$OUT/$NAME.tar.zst.part-"

log "archive done, restarting node"
start_node
log "node restarted"

# ---- checksums and manifest ---------------------------------------------

cd "$OUT"
PARTS_JSONL="$OUT/.parts.jsonl"
: > "$PARTS_JSONL"
: > SHA256SUMS
TOTAL_BYTES=0
for f in "$NAME".tar.zst.part-*; do
    bytes=$(wc -c < "$f" | tr -d ' ')
    [ "$bytes" -lt 2147483648 ] || die "part $f is over the 2GiB release asset limit"
    hash=$(sha256 "$f")
    echo "$hash  $f" >> SHA256SUMS
    jq -n --arg file "$f" --argjson bytes "$bytes" --arg sha256 "$hash" \
        '{file: $file, bytes: $bytes, sha256: $sha256}' >> "$PARTS_JSONL"
    TOTAL_BYTES=$((TOTAL_BYTES + bytes))
done

jq -n \
    --arg name "$NAME" --arg chain "$CHAIN" --arg created "$CREATED" \
    --argjson height "$HEIGHT" --arg bestblockhash "$BESTHASH" \
    --arg subversion "$SUBVERSION" --arg folders "$(echo $FOLDERS)" \
    --argjson txoutsetinfo "$TXOUTSET" --argjson totalbytes "$TOTAL_BYTES" \
    --slurpfile parts "$PARTS_JSONL" \
    '{name: $name, chain: $chain, created: $created, height: $height,
      bestblockhash: $bestblockhash, node: $subversion,
      folders: ($folders | split(" ")), compressed_bytes: $totalbytes,
      restore: "cat *.tar.zst.part-* | zstd -d | tar -x -C <datadir>",
      txoutsetinfo: $txoutsetinfo, parts: $parts}' > manifest.json
rm -f "$PARTS_JSONL"

hash=$(sha256 manifest.json)
echo "$hash  manifest.json" >> SHA256SUMS

if [ -n "$GPG_KEY" ]; then
    gpg --local-user "$GPG_KEY" --armor --detach-sign --output SHA256SUMS.asc SHA256SUMS
    log "signed SHA256SUMS with $GPG_KEY"
fi

TOTAL_GB=$(echo "$TOTAL_BYTES" | awk '{printf "%.1f", $1 / 1073741824}')
PART_COUNT=$(ls "$NAME".tar.zst.part-* | wc -l | tr -d ' ')
log "manifest written: $PART_COUNT parts, ${TOTAL_GB}GB compressed"

if [ "$PUBLISH" = 0 ]; then
    log "publish skipped, files are in $OUT"
    exit 0
fi

# ---- publish ------------------------------------------------------------

DATE_SHORT=$(date -u +%Y-%m-%d)
NOTES="$OUT/.notes.md"
RESTORE_FLAG=""
RESTORE_TARGET="your veil datadir"
if [ "$TESTNET" = 1 ]; then
    RESTORE_FLAG=" --testnet"
    RESTORE_TARGET="the testnet4 folder inside your veil datadir"
fi

cat > "$NOTES" <<EOF
Veil $CHAIN_LABEL snapshot at height $HEIGHT, captured $DATE_SHORT.

Best block hash: $BESTHASH
Contents: $(echo $FOLDERS | sed 's/ /, /g')
Compressed size: ${TOTAL_GB}GB in $PART_COUNT parts
Built with node: $SUBVERSION

Easiest restore, one script that downloads, verifies and unpacks:

    curl -fsSLO https://raw.githubusercontent.com/$REPO/main/restore.sh
    bash restore.sh$RESTORE_FLAG

Verify the download by hand:

    shasum -a 256 -c SHA256SUMS

Or unpack it yourself, with the wallet stopped, into $RESTORE_TARGET:

    cat $NAME.tar.zst.part-* | zstd -d | tar -x

Full restore and verification steps for every platform are in the README:
https://github.com/$REPO#easy-mode
EOF

if ! gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    # testnet releases are never "latest", so the plain download URLs that
    # restore.sh and the README use keep pointing at mainnet
    LATEST_FLAG=""
    [ "$TESTNET" = 1 ] && LATEST_FLAG="--latest=false"
    # shellcheck disable=SC2086
    gh release create "$TAG" -R "$REPO" $LATEST_FLAG \
        --title "Veil $CHAIN_LABEL snapshot, height $HEIGHT ($DATE_SHORT)" \
        --notes-file "$NOTES"
fi

UPLOADS="SHA256SUMS manifest.json"
[ -f SHA256SUMS.asc ] && UPLOADS="$UPLOADS SHA256SUMS.asc"
for f in "$NAME".tar.zst.part-* $UPLOADS; do
    attempt=1
    until gh release upload "$TAG" -R "$REPO" --clobber "$f"; do
        attempt=$((attempt + 1))
        [ "$attempt" -gt 3 ] && die "upload failed 3 times for $f"
        log "retrying upload of $f (attempt $attempt)"
        sleep 10
    done
    log "uploaded $f"
done

URL=$(gh release view "$TAG" -R "$REPO" --json url -q .url)
log "release published: $URL"

cd "$SCRIPT_DIR"
if [ "$KEEP" = 1 ]; then
    log "keeping the built files in $OUT (--keep)"
    log "for seeding these as a torrent, see the README section 'Seeding a torrent'"
    log "done"
else
    rm -rf "$OUT"
    log "local build files cleaned up, done"
fi
