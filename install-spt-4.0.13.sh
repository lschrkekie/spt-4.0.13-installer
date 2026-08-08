#!/usr/bin/env bash
set -euo pipefail

PATCHER_URL="https://spt-patches.modd.in/Patcher_1.1.0.0.46657_to_16.9.0.40087.7z"
PATCHER_NAME="Patcher_1.1.0.0.46657_to_16.9.0.40087.7z"
RELEASE_URL="https://spt-patches.modd.in/SPT-4.0.13-40087-2891fd4.7z"
RELEASE_NAME="SPT-4.0.13-40087-2891fd4.7z"

RETAIL_PATH=""
INSTALL_PATH="$HOME/Games/SPT"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/spt-4.0.13-installer"
SEVEN_ZIP_BIN="7z"
SKIP_COPY=0
SKIP_PATCH=0
SKIP_RELEASE=0
SKIP_VERIFY=0

usage() {
    cat <<EOF
Usage: $0 --retail-path <dir> --install-path <dir> [options]

  --retail-path <dir>    Source EFT retail install (contains EscapeFromTarkov.exe)
  --install-path <dir>   Target folder for the new SPT 4.0.13 install (default: $INSTALL_PATH)
  --cache-dir <dir>      Download cache (default: $CACHE_DIR)
  --seven-zip <bin>      7z binary name/path (default: 7z)
  --skip-copy            Skip copying retail files into install-path
  --skip-patch           Skip extracting + running the downgrade patcher
  --skip-release         Skip downloading/extracting the SPT release archive
  --skip-verify          Skip the pre-patch source file completeness check
  -h, --help             Show this help

No auto-detection of --retail-path on Linux: there is no single standard
install location (Steam library, Proton prefix, Lutris, etc. all differ),
so it must always be passed explicitly here.

Notes:
  patcher.exe is a Windows binary. On Linux this script runs it through
  'wine' if available; without wine, the patch step is skipped with a
  warning and must be completed on Windows (or via this same script there).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --retail-path) RETAIL_PATH="$2"; shift 2 ;;
        --install-path) INSTALL_PATH="$2"; shift 2 ;;
        --cache-dir) CACHE_DIR="$2"; shift 2 ;;
        --seven-zip) SEVEN_ZIP_BIN="$2"; shift 2 ;;
        --skip-copy) SKIP_COPY=1; shift ;;
        --skip-patch) SKIP_PATCH=1; shift ;;
        --skip-release) SKIP_RELEASE=1; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
    esac
done

if [ -z "$INSTALL_PATH" ]; then
    echo "Missing --install-path" >&2
    usage
    exit 1
fi
if [ "$SKIP_COPY" -eq 0 ] && [ -z "$RETAIL_PATH" ]; then
    echo "Missing --retail-path (or pass --skip-copy)" >&2
    usage
    exit 1
fi

step() { printf '\n==> %s\n' "$1"; }

step "Checking prerequisites"
command -v "$SEVEN_ZIP_BIN" >/dev/null 2>&1 || { echo "7z not found. Install p7zip-full or pass --seven-zip." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "curl not found." >&2; exit 1; }
echo "7z: $(command -v "$SEVEN_ZIP_BIN")"

if [ "$SKIP_COPY" -eq 0 ]; then
    if [ ! -f "$RETAIL_PATH/EscapeFromTarkov.exe" ]; then
        echo "RetailPath '$RETAIL_PATH' does not look like an EFT install (missing EscapeFromTarkov.exe)." >&2
        exit 1
    fi
fi

mkdir -p "$INSTALL_PATH" "$CACHE_DIR"

download_with_resume() {
    local url="$1" dest="$2"
    local expected
    expected=$(curl -sI "$url" | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)

    if [ -f "$dest" ]; then
        local existing
        existing=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")
        if [ -n "$expected" ] && [ "$existing" = "$expected" ]; then
            echo "Already downloaded, size matches: $dest"
            return
        fi
    fi

    echo "Downloading $url"
    echo "  -> $dest"
    curl -L -C - --retry 5 --retry-delay 5 -o "$dest" "$url"

    if [ -n "$expected" ]; then
        local final
        final=$(stat -c%s "$dest" 2>/dev/null || stat -f%z "$dest")
        if [ "$final" != "$expected" ]; then
            echo "Download incomplete: got $final bytes, expected $expected. Re-run to resume." >&2
            exit 1
        fi
    fi
}

step "Downloading patcher and SPT 4.0.13 release archive"
PATCHER_ARCHIVE="$CACHE_DIR/$PATCHER_NAME"
RELEASE_ARCHIVE="$CACHE_DIR/$RELEASE_NAME"
download_with_resume "$PATCHER_URL" "$PATCHER_ARCHIVE"
if [ "$SKIP_RELEASE" -eq 0 ]; then
    download_with_resume "$RELEASE_URL" "$RELEASE_ARCHIVE"
fi

verify_source_completeness() {
    local source_root="$1"
    step "Checking source files against patcher manifest (file presence, not a full hash check)"
    echo "No official per-file hash list is published for this build, so this only confirms"
    echo "every file the patcher expects to touch actually exists in '$source_root'."

    local checked=0 missing=0 prefix="SPT_Patches/"
    local missing_list=""
    while IFS= read -r delta_path; do
        [ -n "$delta_path" ] || continue
        case "$delta_path" in
            "$prefix"*) ;;
            *) continue ;;
        esac
        local relative="${delta_path#"$prefix"}"
        relative="${relative%.delta}"
        checked=$((checked + 1))
        if [ ! -f "$source_root/$relative" ]; then
            missing=$((missing + 1))
            if [ "$missing" -le 20 ]; then
                missing_list="$missing_list  $relative"$'\n'
            fi
        fi
    done < <("$SEVEN_ZIP_BIN" l -slt "$PATCHER_ARCHIVE" | sed -n 's/^Path = \(.*\.delta\)$/\1/p' | tr '\\' '/')

    echo "Checked $checked expected source files."
    if [ "$missing" -gt 0 ]; then
        echo "$missing expected source file(s) missing from '$source_root':" >&2
        printf '%s' "$missing_list" >&2
        if [ "$missing" -gt 20 ]; then echo "  ... and $((missing - 20)) more" >&2; fi
        cat >&2 <<EOF
Source integrity check failed. Common cause: antivirus quarantine, or an
incomplete/interrupted copy. Verify game files (Steam: right-click ->
Properties -> Verify integrity; BSG Launcher: repair option), then re-run
(add --skip-verify to bypass once you've confirmed it's a false positive).
EOF
        exit 1
    fi
    echo "All expected source files present."
}

if [ "$SKIP_VERIFY" -eq 0 ] && [ "$SKIP_PATCH" -eq 0 ]; then
    if [ "$SKIP_COPY" -eq 1 ]; then
        verify_source_completeness "$INSTALL_PATH"
    else
        verify_source_completeness "$RETAIL_PATH"
    fi
fi

if [ "$SKIP_COPY" -eq 0 ]; then
    step "Copying retail game files into $INSTALL_PATH"
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --info=progress2 "$RETAIL_PATH"/ "$INSTALL_PATH"/
    else
        cp -a "$RETAIL_PATH"/. "$INSTALL_PATH"/
    fi

    if [ ! -f "$INSTALL_PATH/UnityCrashHandler64.exe" ]; then
        cat >&2 <<EOF
UnityCrashHandler64.exe is missing from '$INSTALL_PATH' after copy.
This file is a common antivirus false-positive target and often gets
quarantined or silently skipped during copy. Restore/re-copy it manually,
then re-run with --skip-copy.
EOF
        exit 1
    fi
fi

if [ "$SKIP_PATCH" -eq 0 ]; then
    step "Extracting patcher into $INSTALL_PATH"
    "$SEVEN_ZIP_BIN" x "$PATCHER_ARCHIVE" -o"$INSTALL_PATH" -y >/dev/null

    if command -v wine >/dev/null 2>&1; then
        step "Running patcher.exe via wine (this can take a while for large bundle files)"
        (cd "$INSTALL_PATH" && wine patcher.exe)

        log_file=$(find "$INSTALL_PATH" -maxdepth 1 -name 'Log_*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
        if [ -n "${log_file:-}" ] && grep -q "EXCEPTION" "$log_file"; then
            echo "Patcher log contains exceptions, review before continuing:" >&2
            grep "EXCEPTION" "$log_file" >&2
            echo "See $log_file" >&2
            exit 1
        fi
        echo "Patch applied cleanly."
    else
        cat >&2 <<EOF
'wine' not found — patcher.exe (Windows binary) was NOT run.
Install wine and re-run with --skip-copy --skip-release, or complete the
patch step on Windows using install-spt-4.0.13.ps1 against this same
'$INSTALL_PATH' folder.
EOF
    fi
fi

if [ "$SKIP_RELEASE" -eq 0 ]; then
    step "Extracting SPT 4.0.13 release archive into $INSTALL_PATH"
    "$SEVEN_ZIP_BIN" x "$RELEASE_ARCHIVE" -o"$INSTALL_PATH" -y >/dev/null
fi

step "Done"
echo "Install target: $INSTALL_PATH"
echo "Next steps:"
echo "  1. Open '$INSTALL_PATH/SPT'"
echo "  2. Run SPT.Server, wait for 'Server has started, happy playing'"
echo "  3. Run SPT.Launcher"
echo "Do not move SPT.Server / SPT.Launcher out of that folder (causes the Watermark error)."
