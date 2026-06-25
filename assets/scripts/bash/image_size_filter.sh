#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s nullglob

###############################################################################
# CONFIG
###############################################################################

SCRIPT_VERSION="6.0.0"
OUT_PREFIX="logo-ewutc"
MANIFEST_NAME="manifest.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$SCRIPT_DIR"
MANIFEST="$WORK_DIR/$MANIFEST_NAME"

###############################################################################
# COLORS
###############################################################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()     { echo -e "${RED}[ERROR]${NC} $*" >&2; }
head_()   { echo -e "${BOLD}${CYAN}$*${NC}"; }

###############################################################################
# HELPERS
###############################################################################

has() { command -v "$1" >/dev/null 2>&1; }

image_cli() {
    if has magick; then
        echo magick
    elif has convert; then
        echo convert
    else
        return 1
    fi
}

image_identify() {
    local cli
    cli=$(image_cli) || return 1
    if [[ "$cli" == "magick" ]]; then
        magick identify "$@"
    else
        identify "$@"
    fi
}

image_convert() {
    local cli
    cli=$(image_cli) || return 1
    if [[ "$cli" == "magick" ]]; then
        magick "$@"
    else
        convert "$@"
    fi
}

require() {
    if has "$1"; then
        ok "$1"
        return 0
    else
        err "$1  ← not found on PATH"
        return 1
    fi
}

bash_major=${BASH_VERSINFO[0]:-0}
bash_minor=${BASH_VERSINFO[1]:-0}

###############################################################################
# PYTHON FILE-OP HELPERS
#
# Every rename and delete is delegated to Python so the operations are immune
# to two Git-Bash / MINGW64 hazards:
#
#   1. Bracket-glob expansion: a directory path like /d/.../logo-[wXh@ext]
#      contains literal "[...]" which bash treats as a character-class glob
#      in unquoted contexts — breaking [[ -f "$path" ]], rm, mv, etc.
#
#   2. Word-splitting on spaces: filenames like "Facebook Profile (180x180).png"
#      would be split on spaces when passed through bash arrays to child
#      processes as separate argv tokens.
#
#   Python's os.rename / os.remove treat paths as raw strings with no glob
#   expansion and no word-splitting.
#
# Cross-device rename note: on Windows, /tmp lives on a different drive than
# /d/..., so os.rename(tmp_in_/tmp, dest_in_/d/) raises a cross-device error.
# All temp files are therefore created in the CURRENT DIRECTORY (same drive).
###############################################################################

py_delete() {
    # py_delete <file>
    python -c "
import os, sys
path = sys.argv[1]
try:
    os.remove(path)
except OSError as e:
    print(f'[ERROR] delete failed: {path}: {e}', file=sys.stderr)
    sys.exit(1)
" "$1"
}

py_rename() {
    # py_rename <src> <dst>
    # No-op when src and dst resolve to the same file (already named correctly).
    python -c "
import os, sys
src, dst = sys.argv[1], sys.argv[2]
if os.path.abspath(src) != os.path.abspath(dst):
    os.rename(src, dst)
" "$1" "$2"
}

py_rename_tmp_then_delete_src() {
    # py_rename_tmp_then_delete_src <tmpfile> <dst> <original_src>
    # Step 1: rename tmpfile → dst   (atomic on same filesystem)
    # Step 2: delete original_src    (only if it differs from dst)
    python -c "
import os, sys
tmp, dst, src = sys.argv[1], sys.argv[2], sys.argv[3]
os.rename(tmp, dst)
if os.path.abspath(src) != os.path.abspath(dst):
    try:
        os.remove(src)
    except FileNotFoundError:
        pass
" "$1" "$2" "$3"
}

py_json_asset() {
    # py_json_asset <original_name> <final_name> <kept_as>
    #               <action> <reason>
    #               <sha256> <width> <height> <dimension> <format>
    #               <frame> <frames_in_source>
    python -c "
import json, sys
(original_name, final_name, kept_as,
 action, reason,
 sha256, width, height, dimension, fmt,
 frame, frames) = sys.argv[1:13]
obj = {
    'original_name':    original_name,
    'final_name':       final_name,
    'kept_as':          kept_as,
    'action':           action,
    'reason':           reason,
    'sha256':           sha256,
    'width':            int(width),
    'height':           int(height),
    'dimension':        dimension,
    'format':           fmt,
    'frame':            int(frame),
    'frames_in_source': int(frames),
}
print(json.dumps(obj))
" "$@"
}

###############################################################################
# HEALTH (internal — used by commands that need deps before running)
###############################################################################

resolve_work_dir() {
    local requested_dir="${1:-}"
    local target_dir

    if [[ -n "$requested_dir" ]]; then
        target_dir="$requested_dir"
        if [[ "$target_dir" != /* ]]; then
            target_dir="$PWD/$target_dir"
        fi
    else
        target_dir="$SCRIPT_DIR"
    fi

    if [[ ! -d "$target_dir" ]]; then
        err "Target directory not found: $target_dir"
        exit 1
    fi

    WORK_DIR="$(cd "$target_dir" && pwd)"
    MANIFEST="$WORK_DIR/$MANIFEST_NAME"
}

_require_process_deps() {
    local fail=0
    if ! image_cli >/dev/null 2>&1; then
        err "ImageMagick CLI not found (need 'magick' or 'convert')"
        fail=1
    fi
    require sha256sum || fail=1
    require python    || fail=1
    (( bash_major > 4 || (bash_major == 4 && bash_minor >= 0) )) \
        || { err "Bash 4+ required (running ${BASH_VERSION})"; fail=1; }
    [[ $fail -eq 0 ]] || { err "Aborting — fix missing dependencies first."; exit 1; }
}

_require_manifest() {
    require python || { err "Aborting."; exit 1; }
    [[ -f "$MANIFEST" ]] \
        || { err "'$MANIFEST' not found — run '$(basename "$0") process' first."; exit 1; }
}

###############################################################################
# PROCESS
#
# For each image file in the current directory:
#
#   SINGLE-FRAME (PNG, JPG, WEBP, GIF, BMP, …)
#     unique content + unique dimension
#       → convert to PNG via ImageMagick (written to a same-directory temp file)
#       → rename temp  →  ${OUT_PREFIX}-[WxH].png
#       → delete original
#       action=renamed  reason=kept
#
#     duplicate pixel hash  (visually identical to an already-kept file)
#       → delete immediately
#       action=deleted  reason=duplicate_content
#
#     duplicate pixel dimension  (same WxH as an already-kept file)
#       → delete immediately
#       action=deleted  reason=duplicate_dimension
#
#     unreadable by ImageMagick
#       → leave untouched
#       action=skipped  reason=unreadable
#
#   MULTI-FRAME CONTAINER (ICO, ICNS, animated GIF, multi-page TIFF, …)
#     unique bundle (by raw file hash)
#       → rename in-place  →  ${OUT_PREFIX}-[W1xH1,W2xH2,…].ext
#       action=renamed  reason=kept
#
#     duplicate bundle
#       → delete immediately
#       action=deleted  reason=duplicate_content
###############################################################################

cmd_process() {
    resolve_work_dir "${1:-}"
    cd "$WORK_DIR"
    _require_process_deps

    # Associative maps for single-frame assets and multi-frame bundles.
    declare -A seen_single_dim
    declare -A seen_single_hash
    declare -A seen_container_sig
    declare -A seen_container_hash

    # Temp file collecting one JSON object per asset (joined at the end).
    # Created in CWD so it lives on the same filesystem as the images,
    # making same-drive renames possible on Windows.
    local tmp
    tmp=".__asset_cleaner_tmp_$$.jsonl"
    : > "$tmp"   # create/truncate

    local total=0 renamed=0 deleted=0 skipped=0 files_scanned=0
    local dup_dim=0 dup_hash=0

    # Per-iteration arrays for multi-frame containers; declared here so they
    # are visible to the whole function and explicitly reset each iteration.
    local frame_dims=() frame_idxs=() frame_fmts=()
    local frame_invalid

    info "Scanning images in: $(pwd)"
    echo

    for f in *; do
        [[ -f "$f" ]] || continue
        # Skip: manifest, this script, and files already produced by a prior run.
        [[ "$f" == "$MANIFEST_NAME"   ]] && continue
        [[ "$f" == "${OUT_PREFIX}-"*   ]] && continue
        [[ "$f" == "$(basename "$0")"  ]] && continue
        [[ "$f" == "$tmp"              ]] && continue

        files_scanned=$((files_scanned + 1))

        # Count embedded sub-images. `identify` prints one line per frame.
        local nframes
        nframes=$(image_identify "$f" 2>/dev/null | wc -l | tr -d '[:space:]' || true)
        [[ "$nframes" =~ ^[0-9]+$ ]] || nframes=0

        if [[ "$nframes" -eq 0 ]]; then
            warn "Unreadable / not an image — skipping: $f"
            skipped=$((skipped + 1))
            total=$((total + 1))
            py_json_asset "$f" "" "" \
                "skipped" "unreadable" \
                "" "0" "0" "" "" "0" "1" >> "$tmp"
            continue
        fi

        # ──────────────────────────────────────────────────────────────────
        # SINGLE-FRAME FILE
        # ──────────────────────────────────────────────────────────────────
        if [[ "$nframes" -eq 1 ]]; then
            local dim fmt hash width height output

            dim=$(image_identify -format "%wx%h" "$f" 2>/dev/null || true)
            if [[ -z "$dim" ]]; then
                warn "Could not read dimensions — skipping: $f"
                skipped=$((skipped + 1))
                total=$((total + 1))
                py_json_asset "$f" "" "" \
                    "skipped" "unreadable" \
                    "" "0" "0" "" "" "0" "1" >> "$tmp"
                continue
            fi

            fmt=$(image_identify -format "%m" "$f" 2>/dev/null \
                  | tr '[:upper:]' '[:lower:]' || true)

            # Hash decoded pixel data so the same logo saved in different
            # formats (PNG vs JPG vs ICO) is recognised as identical content.
            hash=$(image_convert "$f" png:- 2>/dev/null | sha256sum | awk '{print $1}' || true)
            if [[ -z "$hash" ]]; then
                warn "Could not render pixels — skipping: $f"
                skipped=$((skipped + 1))
                total=$((total + 1))
                py_json_asset "$f" "" "" \
                    "skipped" "unreadable" \
                    "" "0" "0" "$dim" "$fmt" "0" "1" >> "$tmp"
                continue
            fi

            width="${dim%x*}"
            height="${dim#*x}"

            local ext="${f##*.}"
            [[ "$ext" == "$f" ]] && ext="bin"
            ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
            output="${OUT_PREFIX}-[${dim}].${ext}"

            # — duplicate by pixel content —
            if [[ -n "${seen_single_hash[$hash]:-}" ]]; then
                local survivor="${seen_single_hash[$hash]}"
                warn "Duplicate content → deleted: $f  (kept: $survivor)"
                py_delete "$f"
                dup_hash=$((dup_hash + 1))
                deleted=$((deleted + 1))
                total=$((total + 1))
                py_json_asset "$f" "" "$survivor" \
                    "deleted" "duplicate_content" \
                    "$hash" "$width" "$height" "$dim" "$fmt" "0" "1" >> "$tmp"
                continue
            fi

            # — duplicate by pixel dimension —
            if [[ -n "${seen_single_dim[$dim]:-}" ]]; then
                local survivor="${seen_single_dim[$dim]}"
                warn "Duplicate dimension → deleted: $f  (kept: $survivor)"
                py_delete "$f"
                dup_dim=$((dup_dim + 1))
                deleted=$((deleted + 1))
                total=$((total + 1))
                py_json_asset "$f" "" "$survivor" \
                    "deleted" "duplicate_dimension" \
                    "$hash" "$width" "$height" "$dim" "$fmt" "0" "1" >> "$tmp"
                continue
            fi

            py_rename "$f" "$output"

            seen_single_dim["$dim"]="$output"
            seen_single_hash["$hash"]="$output"
            renamed=$((renamed + 1))
            total=$((total + 1))
            ok "Renamed: $f  →  $output"

            py_json_asset "$f" "$output" "" \
                "renamed" "kept" \
                "$hash" "$width" "$height" "$dim" "$fmt" "0" "1" >> "$tmp"
            continue
        fi

        # ──────────────────────────────────────────────────────────────────
        # MULTI-FRAME CONTAINER (ICO, ICNS, animated GIF, multi-page TIFF…)
        # Treat the whole bundle as one asset — rename or delete as a unit.
        # ──────────────────────────────────────────────────────────────────

        # Reset per-iteration arrays explicitly (bash `local` inside a loop
        # does NOT re-initialise on each iteration — it only fires once at
        # function entry — so accumulated values from a prior iteration would
        # persist without these resets).
        frame_dims=()
        frame_idxs=()
        frame_fmts=()
        frame_invalid=0

        local idx dim fmt
        for ((idx = 0; idx < nframes; idx++)); do
            local ref="${f}[${idx}]"
            dim=$(image_identify -format "%wx%h" "$ref" 2>/dev/null || true)
            if [[ -z "$dim" ]]; then
                warn "Unreadable frame $idx in: $f"
                frame_invalid=$((frame_invalid + 1))
                continue
            fi
            fmt=$(image_identify -format "%m" "$ref" 2>/dev/null \
                  | tr '[:upper:]' '[:lower:]' || true)
            frame_dims+=("$dim")
            frame_idxs+=("$idx")
            frame_fmts+=("$fmt")
        done

        if [[ ${#frame_dims[@]} -eq 0 ]]; then
            warn "All $nframes frame(s) unreadable — skipping: $f"
            skipped=$((skipped + nframes))
            total=$((total + nframes))
            for ((idx = 0; idx < nframes; idx++)); do
                py_json_asset "$f" "" "" \
                    "skipped" "unreadable" \
                    "" "0" "0" "" "" "$idx" "$nframes" >> "$tmp"
            done
            continue
        fi

        skipped=$((skipped + frame_invalid))

        # Sorted unique size list for the output filename and duplicate matching.
        local sizelist size_sig
        sizelist=$(printf '%s\n' "${frame_dims[@]}" \
                   | sort -u -t x -k1,1n -k2,2n | paste -sd',')
        size_sig="$sizelist"

        # Hash the raw file bytes — two byte-identical bundles are true dups.
        local filehash
        filehash=$(sha256sum "$f" 2>/dev/null | awk '{print $1}' || true)
        if [[ -z "$filehash" ]]; then
            warn "Could not hash — skipping: $f"
            skipped=$((skipped + ${#frame_dims[@]}))
            total=$((total   + ${#frame_dims[@]}))
            for i in "${!frame_idxs[@]}"; do
                local idx="${frame_idxs[$i]}"
                local dim="${frame_dims[$i]}"
                local fmt="${frame_fmts[$i]}"
                local w="${dim%x*}" h="${dim#*x}"
                py_json_asset "$f" "" "" \
                    "skipped" "unreadable" \
                    "" "$w" "$h" "$dim" "$fmt" "$idx" "$nframes" >> "$tmp"
            done
            continue
        fi

        local ext="${f##*.}"
        [[ "$ext" == "$f" ]] && ext="bin"
        ext=$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')
        local output="${OUT_PREFIX}-[${sizelist}].${ext}"

        # — duplicate bundle —
        if [[ -n "${seen_container_hash[$filehash]:-}" ]]; then
            local survivor="${seen_container_hash[$filehash]}"
            warn "Duplicate bundle → deleted: $f  (kept: $survivor)"
            py_delete "$f"
            dup_hash=$((dup_hash + 1))
            deleted=$((deleted + 1))
            for i in "${!frame_idxs[@]}"; do
                local idx="${frame_idxs[$i]}"
                local dim="${frame_dims[$i]}"
                local fmt="${frame_fmts[$i]}"
                local w="${dim%x*}" h="${dim#*x}"
                total=$((total + 1))
                py_json_asset "$f" "" "$survivor" \
                    "deleted" "duplicate_content" \
                    "$filehash" "$w" "$h" "$dim" "$fmt" "$idx" "$nframes" >> "$tmp"
            done
            continue
        fi

        if [[ -n "${seen_container_sig[$size_sig]:-}" ]]; then
            local survivor="${seen_container_sig[$size_sig]}"
            warn "Duplicate container sizes → deleted: $f  (kept: $survivor)"
            py_delete "$f"
            dup_hash=$((dup_hash + 1))
            deleted=$((deleted + 1))
            for i in "${!frame_idxs[@]}"; do
                local idx="${frame_idxs[$i]}"
                local dim="${frame_dims[$i]}"
                local fmt="${frame_fmts[$i]}"
                local w="${dim%x*}" h="${dim#*x}"
                total=$((total + 1))
                py_json_asset "$f" "" "$survivor" \
                    "deleted" "duplicate_content" \
                    "$filehash" "$w" "$h" "$dim" "$fmt" "$idx" "$nframes" >> "$tmp"
            done
            continue
        fi

        # — unique bundle: rename in-place —
        py_rename "$f" "$output"

        seen_container_hash["$filehash"]="$output"
        seen_container_sig["$size_sig"]="$output"

        renamed=$((renamed + 1))
        ok "Renamed: $f  →  $output  (frames: $sizelist)"

        for i in "${!frame_idxs[@]}"; do
            local idx="${frame_idxs[$i]}"
            local dim="${frame_dims[$i]}"
            local fmt="${frame_fmts[$i]}"
            local w="${dim%x*}" h="${dim#*x}"
            total=$((total + 1))
            py_json_asset "$f" "$output" "" \
                "renamed" "kept" \
                "$filehash" "$w" "$h" "$dim" "$fmt" "$idx" "$nframes" >> "$tmp"
        done
    done

    # ── write manifest (append this run to history instead of overwriting) ─
    local assets_json=""
    [[ -s "$tmp" ]] && assets_json=$(paste -sd',' "$tmp")
    py_delete "$tmp" 2>/dev/null || true

    local run_summary_tmp=".__asset_run_summary_$$.json"
    local manifest_tmp=".__asset_manifest_$$.json"
    cat > "$run_summary_tmp" <<JSONEOF
{
  "script_version": "$SCRIPT_VERSION",
  "generated_at":     "$(date -Iseconds)",
  "working_dir":      "$(pwd)",
  "summary": {
    "files_scanned":       $files_scanned,
    "total_assets":        $total,
    "renamed_kept":        $renamed,
    "deleted_dup_content": $dup_hash,
    "deleted_dup_dim":     $dup_dim,
    "skipped_unreadable":  $skipped
  }
}
JSONEOF

    python - "$MANIFEST" "$run_summary_tmp" "$manifest_tmp" "$assets_json" <<'PY'
import json, os, sys
manifest_path, run_summary_path, out_path, assets_json = sys.argv[1:5]


def read_json(path):
    if not path or not os.path.exists(path):
        return {}
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return {}

existing = read_json(manifest_path)
current = read_json(run_summary_path)
current_summary = current.get("summary", {})
current_assets = []
if assets_json.strip():
    try:
        current_assets = json.loads("[" + assets_json + "]")
    except Exception:
        current_assets = []

prev_assets = existing.get("assets") or []
prev_runs = existing.get("runs") or []
if not prev_runs and existing.get("summary") is not None:
    prev_runs = [{
        "generated_at": existing.get("generated_at", current.get("generated_at", "unknown")),
        "working_dir": existing.get("working_dir", current.get("working_dir", "")),
        "summary": existing.get("summary", {}),
        "assets": existing.get("assets") or []
    }]

cumulative = {}
for key in ["files_scanned", "total_assets", "renamed_kept", "deleted_dup_content", "deleted_dup_dim", "skipped_unreadable"]:
    cumulative[key] = int(existing.get("summary", {}).get(key, 0)) + int(current_summary.get(key, 0))

prev_runs.append({
    "generated_at": current.get("generated_at", "unknown"),
    "working_dir": current.get("working_dir", ""),
    "summary": current_summary,
    "assets": current_assets,
})

merged = {
    "manifest_version": existing.get("manifest_version", 6),
    "script_version": current.get("script_version", existing.get("script_version", "6.0.0")),
    "generated_at": current.get("generated_at", existing.get("generated_at", "unknown")),
    "working_dir": current.get("working_dir", existing.get("working_dir", "")),
    "summary": cumulative,
    "runs": prev_runs,
    "assets": prev_assets + current_assets,
}

with open(out_path, "w") as fh:
    json.dump(merged, fh, indent=2)
PY

    mv "$manifest_tmp" "$MANIFEST"
    py_delete "$run_summary_tmp" 2>/dev/null || true

    echo
    ok "Manifest written: $MANIFEST"
    echo
    head_ "═══ PROCESS SUMMARY ═══"
    printf "  %-22s %s\n" "Files scanned:"      "$files_scanned"
    printf "  %-22s %s\n" "Renamed (kept):"      "$renamed"
    printf "  %-22s %s\n" "Deleted (dup hash):"  "$dup_hash"
    printf "  %-22s %s\n" "Deleted (dup dim):"   "$dup_dim"
    printf "  %-22s %s\n" "Skipped (unreadable):" "$skipped"
    echo
}

###############################################################################
# VERIFY
#
# Checks three things:
#   1. Every file with action=renamed still exists on disk with its final_name.
#   2. No two kept entries accidentally share the same final_name (collision).
#   3. Files with action=skipped (unreadable) are still present — reminds the
#      user they were left untouched and may need manual attention.
###############################################################################

cmd_verify() {
    resolve_work_dir "${1:-}"
    cd "$WORK_DIR"
    _require_manifest

    python -c '
import json, os, sys

manifest_path = sys.argv[1]
GREEN  = "\033[0;32m"
YELLOW = "\033[1;33m"
RED    = "\033[0;31m"
CYAN   = "\033[0;36m"
BOLD   = "\033[1m"
NC     = "\033[0m"

def ok(msg):   print(f"{GREEN}[OK]   {NC} {msg}")
def warn(msg): print(f"{YELLOW}[WARN] {NC} {msg}")
def miss(msg): print(f"{RED}[MISS] {NC} {msg}")
def info(msg): print(f"{CYAN}{BOLD}{msg}{NC}")

with open(manifest_path) as f:
    data = json.load(f)

assets = data.get("assets", [])
generated = data.get("generated_at", "unknown")
working_dir = data.get("working_dir", "unknown")

print()
info("═══ VERIFY REPORT ═══")
print(f"  Manifest generated : {generated}")
print(f"  Working directory  : {working_dir}")
print()

# ── 1. Kept files present on disk ──────────────────────────────────────────
info("── Kept outputs ──")
kept_assets = [a for a in assets if a.get("action") == "renamed"]
# Deduplicate by final_name (multi-frame containers produce one entry per frame
# but all share the same final_name — count the file once).
seen_finals = {}
for a in kept_assets:
    fn = a.get("final_name", "")
    if fn and fn not in seen_finals:
        seen_finals[fn] = a["original_name"]

ok_count = miss_count = 0
if seen_finals:
    for final_name, original_name in sorted(seen_finals.items()):
        if os.path.isfile(final_name):
            ok(f"{final_name}  (was: {original_name})")
            ok_count += 1
        else:
            miss(f"{final_name}  (was: {original_name})  ← FILE MISSING")
            miss_count += 1
else:
    print("  (no kept outputs recorded)")

print()
info("── Deleted files (expected absent) ──")
deleted_assets = [a for a in assets if a.get("action") == "deleted"]
seen_deleted = {}
for a in deleted_assets:
    on = a.get("original_name", "")
    if on and on not in seen_deleted:
        seen_deleted[on] = a.get("kept_as", "")

phantom_count = 0
if seen_deleted:
    for original_name, kept_as in sorted(seen_deleted.items()):
        if os.path.isfile(original_name):
            warn(f"{original_name}  ← should be deleted but still exists on disk")
            phantom_count += 1
        # If not on disk (expected), nothing to print — silent is clean.
    if phantom_count == 0:
        print("  All deleted files confirmed absent — directory is clean.")
else:
    print("  (no deleted files recorded)")

print()
info("── Skipped / unreadable files ──")
skipped_assets = [a for a in assets if a.get("action") == "skipped"]
seen_skipped = {}
for a in skipped_assets:
    on = a.get("original_name", "")
    if on and on not in seen_skipped:
        seen_skipped[on] = True

still_present = 0
if seen_skipped:
    for original_name in sorted(seen_skipped.keys()):
        if os.path.isfile(original_name):
            warn(f"{original_name}  ← unreadable file still present (needs manual review)")
            still_present += 1
    if still_present == 0:
        print("  (all previously skipped files are gone)")
else:
    print("  (none)")

# ── summary ────────────────────────────────────────────────────────────────
print()
info("── Summary ──")
print(f"  Kept outputs    OK   : {ok_count}")
print(f"  Kept outputs    MISS : {miss_count}")
print(f"  Deleted phantoms     : {phantom_count}")
print(f"  Skipped still present: {still_present}")
if miss_count == 0 and phantom_count == 0:
    print()
    print(f"{GREEN}  ✓ Directory is in the expected state.{NC}")
else:
    print()
    print(f"{YELLOW}  ✗ Discrepancies found — review the items above.{NC}")
print()
' "$MANIFEST"
}

###############################################################################
# STATS
###############################################################################

cmd_stats() {
    resolve_work_dir "${1:-}"
    cd "$WORK_DIR"
    _require_manifest

    python -c '
import json, sys
from collections import Counter

manifest_path = sys.argv[1]
CYAN  = "\033[0;36m"
BOLD  = "\033[1m"
NC    = "\033[0m"

def head(msg): print(f"{BOLD}{CYAN}{msg}{NC}")

with open(manifest_path) as f:
    data = json.load(f)

s = data.get("summary", {})
assets = data.get("assets", [])

print()
head("═══ MANIFEST INFO ═══")
print(f"  manifest_version : {data.get('manifest_version', '?')}")
print(f"  script_version   : {data.get('script_version',  '?')}")
print(f"  generated_at     : {data.get('generated_at',    '?')}")
print(f"  working_dir      : {data.get('working_dir',     '?')}")

print()
head("═══ PROCESS SUMMARY ═══")
print(f"  {'files_scanned':<25} {s.get('files_scanned',       0)}")
print(f"  {'total_assets':<25} {s.get('total_assets',         0)}")
print(f"  {'renamed_kept':<25} {s.get('renamed_kept',         0)}")
print(f"  {'deleted_dup_content':<25} {s.get('deleted_dup_content', 0)}")
print(f"  {'deleted_dup_dim':<25} {s.get('deleted_dup_dim',    0)}")
print(f"  {'skipped_unreadable':<25} {s.get('skipped_unreadable',  0)}")

print()
head("═══ KEPT FILES (on disk) ═══")
kept = {}
for a in assets:
    if a.get("action") == "renamed":
        fn = a.get("final_name", "")
        if fn and fn not in kept:
            kept[fn] = a.get("dimension", "?")

if kept:
    for fn in sorted(kept):
        print(f"  {kept[fn]:<14}  {fn}")
else:
    print("  (none)")

print()
head("═══ DELETED FILES (by reason) ═══")
by_reason = Counter(
    a.get("reason", "?")
    for a in assets
    if a.get("action") == "deleted"
)
if by_reason:
    for reason, count in sorted(by_reason.items()):
        print(f"  {reason:<28} {count}")
else:
    print("  (none)")

print()
head("═══ SKIPPED FILES ═══")
skipped = [a.get("original_name", "") for a in assets if a.get("action") == "skipped"]
seen = set()
for name in skipped:
    if name and name not in seen:
        seen.add(name)
        print(f"  {name}")
if not seen:
    print("  (none)")
print()
' "$MANIFEST"
}

###############################################################################
# HEALTH
###############################################################################

cmd_health() {
    echo
    head_ "═══ SYSTEM HEALTH CHECK ═══"
    echo

    info "Bash version"
    if (( bash_major > 4 || (bash_major == 4 && bash_minor >= 0) )); then
        ok "bash ${BASH_VERSION}  (4+ required)"
    else
        err "bash ${BASH_VERSION}  — version 4.0+ required"
    fi
    echo

    info "Required tools"
    local all_ok=1

    if has magick; then
        local im_ver
        im_ver=$(magick --version 2>/dev/null | head -1 || true)
        ok "magick   — $im_ver"
    elif has convert; then
        local im_ver
        im_ver=$(convert --version 2>/dev/null | head -1 || true)
        ok "convert  — $im_ver"
    else
        err "ImageMagick CLI — NOT FOUND  (install ImageMagick 7+; 'magick' or 'convert' is required)"
        all_ok=0
    fi

    if has sha256sum; then
        ok "sha256sum"
    else
        err "sha256sum — NOT FOUND  (install GNU coreutils)"
        all_ok=0
    fi

    if has python; then
        local py_ver
        py_ver=$(python --version 2>&1 || true)
        ok "python   — $py_ver"
    else
        err "python   — NOT FOUND  (install Python 3)"
        all_ok=0
    fi

    echo
    if [[ $all_ok -eq 1 ]]; then
        ok "All dependencies satisfied — ready to run."
    else
        err "One or more dependencies missing — fix above before running 'process'."
    fi
    echo
}

###############################################################################
# HELP
###############################################################################

cmd_help() {
    local topic="${1:-}"
    local prog
    prog=$(basename "$0")

    case "$topic" in

        # ── process ──────────────────────────────────────────────────────────
        process)
            cat <<EOF

NAME
    $prog process  —  scan, deduplicate, and rename logo images in-place

USAGE
    $prog [process|verify|stats|health|help] [target-dir]

DESCRIPTION
    Scans every regular file in the current directory. Skips:
      • $MANIFEST
      • this script itself
      • files already named "${OUT_PREFIX}-*" (output of a prior run)

    Each image is classified and acted on immediately:

    ┌─────────────────────────────┬────────────┬────────────────────────┐
    │ Condition                   │ Action     │ Final state on disk    │
    ├─────────────────────────────┼────────────┼────────────────────────┤
    │ Unique content + dimension  │ renamed    │ ${OUT_PREFIX}-[WxH].png     │
    │   (multi-frame container)   │ renamed    │ ${OUT_PREFIX}-[W1xH1,…].ext │
    │ Duplicate pixel hash        │ deleted    │ gone                   │
    │ Duplicate pixel dimensions  │ deleted    │ gone                   │
    │ Unreadable by ImageMagick   │ skipped    │ untouched              │
    └─────────────────────────────┴────────────┴────────────────────────┘

    Single-frame images (PNG, JPG, WEBP, BMP, …):
      The file is renamed in place using its original extension and the
      size suffix, for example: ${OUT_PREFIX}-[120x120].jpg. The original
      file is replaced by the renamed output and duplicates are deleted.

    Multi-frame containers (ICO, ICNS, animated GIF, multi-page TIFF, …):
      The bundle is renamed in-place — no frame extraction, the container
      is preserved exactly as-is.

    Duplicate detection:
      • Content hash  — SHA-256 of the decoded pixel data (not raw bytes),
        so the same logo saved as both PNG and ICO is a single content dup.
      • Dimension     — same WxH pixel size as an already-kept image.
      • Multi-frame bundles use a raw file hash (SHA-256 of file bytes).

    All file system operations (rename, delete) are performed by Python,
    making them immune to:
      • bash glob-expansion on paths containing [ ] brackets
      • word-splitting on filenames containing spaces

    Results are written to $MANIFEST.

MANIFEST FIELDS (per asset)
    original_name     filename before processing
    final_name        filename now on disk  (empty if deleted/skipped)
    kept_as           for deleted files: the final_name of the survivor
    action            renamed | deleted | skipped
    reason            kept | duplicate_content | duplicate_dimension | unreadable
    sha256            pixel hash (single-frame) or raw file hash (multi-frame)
    width / height    pixel dimensions
    dimension         "WxH" string
    format            image format in lowercase
    frame             0-based sub-image index within the source container
    frames_in_source  total frames in the source container

REQUIRES
    magick (ImageMagick 7+), sha256sum, python, bash 4+

EOF
            ;;

        # ── verify ───────────────────────────────────────────────────────────
        verify)
            cat <<EOF

NAME
    $prog verify  —  confirm the directory matches the manifest

USAGE
    $prog verify

DESCRIPTION
    Reads $MANIFEST and runs three checks:

    1. KEPT OUTPUTS — every file with action=renamed should still exist
       on disk with its final_name.
       Reports OK (present) or MISS (missing) for each.

    2. DELETED FILES — every file with action=deleted should NOT exist
       on disk. Reports a warning for any that somehow still exist
       ("phantom" files).

    3. SKIPPED FILES — every file with action=skipped was left untouched
       and should still exist. Reports a warning for each, reminding
       you that it needs manual review.

    Exits with a clean summary indicating whether the directory is in
    the expected state.

REQUIRES
    python, an existing $MANIFEST  (run "$prog process" first)

EOF
            ;;

        # ── stats ─────────────────────────────────────────────────────────────
        stats)
            cat <<EOF

NAME
    $prog stats  —  print a full report from the manifest

USAGE
    $prog stats

DESCRIPTION
    Reads $MANIFEST and prints:

      • Manifest metadata (version, script version, timestamp, directory)
      • Process summary counts (scanned, renamed, deleted, skipped)
      • Full list of kept files currently on disk with their dimensions
      • Breakdown of deleted files by reason
      • List of any skipped (unreadable) files

REQUIRES
    python, an existing $MANIFEST  (run "$prog process" first)

EOF
            ;;

        # ── health ────────────────────────────────────────────────────────────
        health)
            cat <<EOF

NAME
    $prog health  —  check all required dependencies

USAGE
    $prog health

DESCRIPTION
    Checks that the following are installed and accessible on PATH:

      magick      ImageMagick 7+ CLI  (must be "magick", not "convert")
      sha256sum   GNU coreutils hash utility
      python      Python 3 interpreter

    Also verifies the running bash version is 4.0+.

    Prints the detected version of each tool so you can confirm you have
    the right versions before running "process".

    Does not require a manifest to be present.

EOF
            ;;

        # ── overview ──────────────────────────────────────────────────────────
        "")
            cat <<EOF

NAME
    $prog  —  deduplicate and standardise logo image assets

VERSION
    $SCRIPT_VERSION

SYNOPSIS
    $prog [COMMAND]

DESCRIPTION
    Processes every image in the target directory (defaults to the script directory when no path is provided):

      • Unique images are renamed in-place to "${OUT_PREFIX}-[WxH].ext"
        (converted to PNG for single-frame formats).
      • Duplicate images (same pixel content or same pixel dimensions)
        are deleted immediately.
      • Unreadable files are left untouched with a warning.
      • No originals are preserved. No separate output directory is
        created. No manual cleanup step is needed.

    Everything that happens — every rename, every deletion, every skip —
    is recorded in $MANIFEST for auditing and verification.

COMMANDS
    process          Scan, deduplicate, rename/delete in-place.
                     Writes $MANIFEST.  (default when no command given)

    verify           Check the directory matches the manifest:
                     kept files exist, deleted files are gone,
                     skipped files are flagged for review.

    stats            Print full stats from $MANIFEST: summary counts,
                     list of kept files, deletion breakdown, skipped files.

    health           Verify all required tools are installed and show
                     their versions.

    help [COMMAND]   Show this overview, or detailed help for a command.

EXAMPLES
    $prog                    # same as: $prog process
    $prog process
    $prog process /path/to/folder
    $prog verify /path/to/folder
    $prog stats /path/to/folder
    $prog health
    $prog help process
    $prog help verify

REQUIREMENTS
    bash 4+,  ImageMagick 7+ (magick),  sha256sum,  python 3

FILES
    $MANIFEST
        JSON audit log of every file processed: what it was named,
        what it is named now, what action was taken, and why.

MANIFEST SCHEMA
    manifest_version      6
    script_version        semantic version of this script
    generated_at          ISO-8601 timestamp
    working_dir           absolute path where process was run
    summary               aggregate counts (see "stats" output)
    assets[]
      original_name       filename before processing
      final_name          filename now on disk  (empty if deleted/skipped)
      kept_as             for deleted files: survivor's final_name
      action              renamed | deleted | skipped
      reason              kept | duplicate_content |
                          duplicate_dimension | unreadable
      sha256              pixel hash or raw file hash
      width / height      pixel dimensions
      dimension           "WxH"
      format              lowercase format string
      frame               sub-image index (0 for single-frame files)
      frames_in_source    total frames in the source container

EOF
            ;;

        *)
            err "No help available for: '$topic'"
            echo "Run '$prog help' for the list of commands."
            return 1
            ;;
    esac
}

###############################################################################
# ROUTER
###############################################################################

case "${1:-process}" in
    process)
        cmd_process "${2:-}"
        ;;
    verify)
        cmd_verify "${2:-}"
        ;;
    stats)
        cmd_stats "${2:-}"
        ;;
    health)
        cmd_health
        ;;
    help|-h|--help)
        cmd_help "${2:-}"
        ;;
    "")
        cmd_process "${2:-}"
        ;;
    *)
        if [[ -d "$1" ]]; then
            cmd_process "$1"
        else
            err "Unknown command: '${1}'"
            echo "  Valid commands: process | verify | stats | health | help"
            echo "  Run '$(basename "$0") help' for details."
            exit 1
        fi
        ;;
esac