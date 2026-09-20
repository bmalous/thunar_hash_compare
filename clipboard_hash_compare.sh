#!/usr/bin/env bash
set -euo pipefail

SCRIPT_TITLE="Thunar Hash Compare"
export LC_ALL=C

if (( BASH_VERSINFO[0] < 4 )); then
    printf 'Error: Bash 4 or newer is required (found %s).\n' "$BASH_VERSION" >&2
    exit 2
fi

show_dialog() {
    local dialog_type="$1"
    local message="$2"

    # Keep results available even when the desktop dialog fails or is closed.
    if [[ "$dialog_type" == "error" ]]; then
        printf 'Error: %s\n' "$message" >&2
    else
        printf '%s\n' "$message"
    fi
    if [[ "${CLIPBOARD_HASH_COMPARE_NO_GUI:-0}" != "1" ]] \
        && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] \
        && command -v zenity >/dev/null 2>&1; then
        if [[ "$dialog_type" == "error" ]]; then
            zenity --error --no-markup --no-wrap --title="$SCRIPT_TITLE" --text="$message" || true
        else
            zenity --info --no-markup --no-wrap --title="$SCRIPT_TITLE" --text="$message" || true
        fi
    fi
}

fail() {
    show_dialog error "$1"
    exit 2
}

extract_clipboard() {
    local content=""
    local attempted=0
    if [[ -n "${CLIPBOARD_HASH_COMPARE_TEXT+x}" ]]; then
        printf '%s' "$CLIPBOARD_HASH_COMPARE_TEXT"
        return
    fi

    if [[ -n "${WAYLAND_DISPLAY:-}" ]] && command -v wl-paste >/dev/null 2>&1; then
        attempted=1
        if content=$(wl-paste --no-newline 2>/dev/null); then
            printf '%s' "$content"
            return
        fi
    fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xclip >/dev/null 2>&1; then
        attempted=1
        if content=$(xclip -selection clipboard -o 2>/dev/null); then
            printf '%s' "$content"
            return
        fi
    fi
    if [[ -n "${DISPLAY:-}" ]] && command -v xsel >/dev/null 2>&1; then
        attempted=1
        if content=$(xsel --clipboard --output 2>/dev/null); then
            printf '%s' "$content"
            return
        fi
    fi
    if [[ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ]] && command -v powershell.exe >/dev/null 2>&1; then
        attempted=1
        if content=$(powershell.exe -NoLogo -NoProfile -NonInteractive -Command \
            '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; $ErrorActionPreference = "Stop"; Get-Clipboard -Raw' 2>/dev/null); then
            printf '%s' "$content"
            return
        fi
    fi
    if (( attempted )); then
        fail "Unable to read the clipboard. Check your desktop session or WSL Windows interoperability."
    fi
    fail "No usable clipboard utility found. Install wl-clipboard (Wayland) or xclip/xsel (X11), or enable powershell.exe in WSL."
}

sanitize_hash() {
    local raw="$1"
    local trimmed compact first_field

    # First accept a bare digest, including one wrapped over multiple lines.
    trimmed=$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    # Do not merge records whose filenames happen to consist of hex digits.
    if [[ $(printf '%s\n' "$trimmed" | awk 'NF { n++ } NF > 1 { fields=1 } END { print (n > 1 && fields) ? 1 : 0 }') == 1 ]]; then
        fail "Clipboard contains multiple records. Copy one digest or one checksum line."
    fi
    compact=$(printf '%s' "$trimmed" | tr -d '[:space:]')
    if [[ -n "$compact" && "$compact" =~ ^[[:xdigit:]]+$ ]]; then
        printf '%s' "$compact"
        return
    fi

    # Also accept conventional checksum output: "digest  filename" or
    # "digest *filename". Reject lists instead of silently selecting one hash.
    if [[ $(printf '%s\n' "$trimmed" | awk 'NF { n++ } END { print n+0 }') -gt 1 ]]; then
        fail "Clipboard contains multiple records. Copy one digest or one checksum line."
    fi
    first_field=$(printf '%s\n' "$trimmed" | awk 'NF { print $1; exit }')
    # GNU checksum tools escape the record when the filename contains a backslash.
    first_field=${first_field#\\}
    printf '%s' "$first_field"
}

# Algorithms whose digest is exactly $1 hex characters long, given the variants
# this script actually computes: BLAKE2b/BLAKE2s and BLAKE3 at their default
# output sizes (64/32/32 bytes) and XXHash as XXH64 (8 bytes).
get_possible_algorithms() {
    local hash_len="$1"
    local algorithms=()

    case "$hash_len" in
        8)
            algorithms+=(CRC32 Adler32)
            ;;
        16)
            algorithms+=(XXHash)
            ;;
        32)
            algorithms+=(MD5)
            ;;
        40)
            algorithms+=(SHA1 RIPEMD)
            ;;
        56)
            algorithms+=(SHA224 SHA3-224)
            ;;
        64)
            algorithms+=(SHA256 SHA3-256 BLAKE2s BLAKE3)
            ;;
        96)
            algorithms+=(SHA384 SHA3-384)
            ;;
        128)
            algorithms+=(SHA512 SHA3-512 BLAKE2b WHIRLPOOL)
            ;;
    esac

    printf '%s\n' "${algorithms[@]}"
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    printf 'Usage: %s [--] FILE...\nCompare one clipboard digest with selected files.\nExit: 0 = any match, 1 = no match, 2 = error or incomplete comparison.\n' "${0##*/}"
    exit 0
fi
if [[ ${1:-} == -- ]]; then
    shift
fi
if [[ $# -lt 1 ]]; then
    fail "No files provided."
fi

if ! command -v python3 >/dev/null 2>&1; then
    fail "python3 is required but not found in PATH."
fi

clipboard_raw=$(extract_clipboard) || exit 2
clipboard=$(sanitize_hash "$clipboard_raw") || exit 2

if [[ -z "$clipboard" ]]; then
    fail "Clipboard does not contain any text."
fi

if [[ ! "$clipboard" =~ ^[[:xdigit:]]+$ ]]; then
    fail "Clipboard content is not a hexadecimal hash."
fi

clipboard_lower=${clipboard,,}
hash_len=${#clipboard}
case "$hash_len" in
    8|16|32|40|56|64|96|128)
        ;;
    *)
        fail "Clipboard hash length ($hash_len) is not supported."
        ;;
esac

mapfile -t possible_algorithms < <(get_possible_algorithms "$hash_len")
declare -A wanted_algorithms=()
for algo in "${possible_algorithms[@]}"; do
    wanted_algorithms["$algo"]=1
done

declare -a dialog_lines=()
overall_status=0
any_match=0

ordered_algorithms=(
    MD5
    SHA1
    SHA224
    SHA256
    SHA384
    SHA512
    SHA3-224
    SHA3-256
    SHA3-384
    SHA3-512
    BLAKE2b
    BLAKE2s
    BLAKE3
    WHIRLPOOL
    RIPEMD
    XXHash
    CRC32
    Adler32
)

for target in "$@"; do
    # A literal '-' must never become standard input to a fallback tool.
    [[ "$target" == /* ]] || target="./$target"
    if [[ ! -e "$target" ]]; then
        dialog_lines+=("$target: File not found")
        overall_status=2
        continue
    fi
    if [[ -d "$target" ]]; then
        dialog_lines+=("$target: Is a directory")
        overall_status=2
        continue
    fi
    if [[ ! -f "$target" ]]; then
        dialog_lines+=("$target: Not a regular file")
        overall_status=2
        continue
    fi
    if [[ ! -r "$target" ]]; then
        dialog_lines+=("$target: Permission denied")
        overall_status=2
        continue
    fi

    if python_output=$(python3 - "$target" "${possible_algorithms[@]}" <<'PYBLOCK'
import binascii
import hashlib
import sys
import zlib
from pathlib import Path

path = Path(sys.argv[1])
wanted = set(sys.argv[2:])
if not path.exists():
    print(f"ERROR not-found {path}")
    sys.exit(1)
if not path.is_file():
    print(f"ERROR not-file {path}")
    sys.exit(1)

hashlib_funcs = [
    ("MD5", "md5"),
    ("SHA1", "sha1"),
    ("SHA224", "sha224"),
    ("SHA256", "sha256"),
    ("SHA384", "sha384"),
    ("SHA512", "sha512"),
    ("SHA3-224", "sha3_224"),
    ("SHA3-256", "sha3_256"),
    ("SHA3-384", "sha3_384"),
    ("SHA3-512", "sha3_512"),
    ("BLAKE2b", "blake2b"),
    ("BLAKE2s", "blake2s"),
]

hashers = []
missing = set()

for name, attr in hashlib_funcs:
    if name not in wanted:
        continue
    func = getattr(hashlib, attr, None)
    if func is None:
        missing.add(name)
        continue
    try:
        hashers.append((name, func()))
    except Exception:
        missing.add(name)

if "WHIRLPOOL" in wanted and "whirlpool" in hashlib.algorithms_available:
    try:
        hashers.append(("WHIRLPOOL", hashlib.new("whirlpool")))
    except Exception:
        missing.add("WHIRLPOOL")
elif "WHIRLPOOL" in wanted:
    missing.add("WHIRLPOOL")

if "RIPEMD" in wanted and "ripemd160" in hashlib.algorithms_available:
    try:
        hashers.append(("RIPEMD", hashlib.new("ripemd160")))
    except Exception:
        missing.add("RIPEMD")
elif "RIPEMD" in wanted:
    missing.add("RIPEMD")

if "BLAKE3" in wanted:
    try:
        import blake3
        hashers.append(("BLAKE3", blake3.blake3()))
    except Exception:
        missing.add("BLAKE3")

if "XXHash" in wanted:
    try:
        import xxhash
        hashers.append(("XXHash", xxhash.xxh64()))
    except Exception:
        missing.add("XXHash")

crc32_value = 0
adler32_value = 1
chunk_size = 1024 * 1024
try:
    with path.open('rb') as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            for _, hasher in hashers:
                hasher.update(chunk)
            if "CRC32" in wanted:
                crc32_value = binascii.crc32(chunk, crc32_value)
            if "Adler32" in wanted:
                adler32_value = zlib.adler32(chunk, adler32_value)
except Exception as exc:
    print(f"ERROR read-failed {exc}")
    sys.exit(1)

computed = {}
for name, hasher in hashers:
    try:
        computed[name] = hasher.hexdigest().lower()
    except Exception:
        missing.add(name)

if "CRC32" in wanted:
    computed["CRC32"] = f"{crc32_value & 0xffffffff:08x}"
if "Adler32" in wanted:
    computed["Adler32"] = f"{adler32_value & 0xffffffff:08x}"

for name in sorted(computed):
    print(f"COMPUTED {name} {computed[name]}")

for name in sorted(missing):
    if name not in computed:
        print(f"MISSING {name}")
PYBLOCK
    ); then
        :
    else
        base_name=$(basename -- "$target")
        python_error=$(printf '%s\n' "$python_output" | sed -n 's/^ERROR [^ ]* //p' | head -n1)
        if [[ -z "$python_error" ]]; then
            python_error="Python hashing process failed"
        fi
        dialog_lines+=("$base_name: Hashing failed: $python_error")
        overall_status=2
        continue
    fi

    unset computed_hashes
    declare -A computed_hashes=()
    unset missing_map
    declare -A missing_map=()

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ $line == COMPUTED* ]]; then
            read -r _ algo digest <<<"$line"
            computed_hashes["$algo"]="$digest"
        elif [[ $line == MISSING* ]]; then
            read -r _ algo <<<"$line"
            missing_map["$algo"]=1
        elif [[ $line == ERROR* ]]; then
            missing_map["ERROR"]=1
        fi
    done <<<"$python_output"

    if [[ -n "${missing_map[BLAKE3]:-}" && -n "${wanted_algorithms[BLAKE3]:-}" ]] && command -v b3sum >/dev/null 2>&1; then
        if output=$(b3sum < "$target" 2>/dev/null); then
            digest=$(printf '%s' "$output" | awk '{print $1}')
            digest=${digest,,}
            if [[ $digest =~ ^[0-9a-f]+$ && ${#digest} -eq hash_len ]]; then
                computed_hashes["BLAKE3"]="$digest"
                unset 'missing_map[BLAKE3]'
            fi
        fi
    fi

    if [[ -n "${missing_map[WHIRLPOOL]:-}" && -n "${wanted_algorithms[WHIRLPOOL]:-}" ]] && command -v openssl >/dev/null 2>&1; then
        output=""
        if output=$(openssl dgst -whirlpool < "$target" 2>/dev/null) \
            || output=$(openssl dgst -provider default -provider legacy -whirlpool < "$target" 2>/dev/null); then
            digest=$(printf '%s' "$output" | awk '{print $NF}')
            digest=${digest,,}
            if [[ $digest =~ ^[0-9a-f]+$ && ${#digest} -eq hash_len ]]; then
                computed_hashes["WHIRLPOOL"]="$digest"
                unset 'missing_map[WHIRLPOOL]'
            fi
        fi
    fi

    if [[ -n "${missing_map[RIPEMD]:-}" && -n "${wanted_algorithms[RIPEMD]:-}" ]] && command -v openssl >/dev/null 2>&1; then
        output=""
        if output=$(openssl dgst -ripemd160 < "$target" 2>/dev/null) \
            || output=$(openssl dgst -provider default -provider legacy -ripemd160 < "$target" 2>/dev/null); then
            digest=$(printf '%s' "$output" | awk '{print $NF}')
            digest=${digest,,}
            if [[ $digest =~ ^[0-9a-f]+$ && ${#digest} -eq hash_len ]]; then
                computed_hashes["RIPEMD"]="$digest"
                unset 'missing_map[RIPEMD]'
            fi
        fi
    fi

    if [[ -n "${missing_map[XXHash]:-}" && -n "${wanted_algorithms[XXHash]:-}" ]] && command -v xxhsum >/dev/null 2>&1; then
        if output=$(xxhsum -H1 < "$target" 2>/dev/null); then
            digest=$(printf '%s' "$output" | awk '{print $1}')
            digest=${digest,,}
            if [[ $digest =~ ^[0-9a-f]+$ && ${#digest} -eq hash_len ]]; then
                computed_hashes["XXHash"]="$digest"
                unset 'missing_map[XXHash]'
            fi
        fi
    fi

    # ordered_algorithms drives the display order; wanted_algorithms restricts
    # the comparison to the digest sizes the clipboard hash could actually be.
    matches=()
    unavailable=()
    for algo in "${ordered_algorithms[@]}"; do
        [[ -n "${wanted_algorithms[$algo]:-}" ]] || continue
        if [[ -n "${computed_hashes[$algo]:-}" ]]; then
            if [[ "${computed_hashes[$algo]}" == "$clipboard_lower" ]]; then
                matches+=("$algo")
            fi
        else
            unavailable+=("$algo")
        fi
    done

    base_name=$(basename -- "$target")
    if [[ ${#matches[@]} -gt 0 ]]; then
        any_match=1
        if [[ ${#unavailable[@]} -gt 0 ]]; then
            dialog_lines+=("$base_name: Matched ${matches[*]} (not checked: ${unavailable[*]})")
        else
            dialog_lines+=("$base_name: Matched ${matches[*]}")
        fi
    elif [[ ${#unavailable[@]} -gt 0 ]]; then
        dialog_lines+=("$base_name: No match among checked algorithms; unable to check ${unavailable[*]}")
        overall_status=2
    else
        dialog_lines+=("$base_name: Did not Match")
        if (( overall_status == 0 )); then
            overall_status=1
        fi
    fi

done

message=$(printf '%s\n' "${dialog_lines[@]}")
show_dialog info "$message"
if (( overall_status == 1 && any_match == 1 )); then
    overall_status=0
fi
exit "$overall_status"
