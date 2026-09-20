# Clipboard Hash Compare

Compare a checksum copied to your clipboard with one or more local files. Designed for Linux terminals and Thunar custom actions, with Windows clipboard access in WSL.

The script infers possible algorithms from the digest length and checks all available candidates. Files are streamed in 1 MiB chunks; Python computes candidate hashes in one pass. Optional command-line fallbacks may read the file again.

## Requirements

- Bash 4 or newer (not POSIX `sh`).
- Python 3.6 or newer; use a currently maintained Python release.
- Standard Unix utilities: `awk`, `sed`, `tr`, `head`, and `basename`.
- A clipboard reader: `wl-paste` from `wl-clipboard` for Wayland, or `xclip`/`xsel` for X11. WSL can also use Windows `powershell.exe` with interoperability enabled.
- Optional: Zenity for desktop dialogs. Results are always printed to the terminal too.

For Ubuntu/Debian, install the clipboard package matching your desktop:

```bash
sudo apt install bash python3 wl-clipboard zenity  # Wayland
sudo apt install xclip                          # X11 alternative
```

WSL uses Linux paths such as `/mnt/c/Users/you/Downloads/file.iso`. Clipboard readers are tried in order: Wayland, X11 (`xclip`, then `xsel`), Windows PowerShell in WSL. A successfully read empty clipboard is reported as empty; another backend is tried only if the read fails. Headless use is supported through the text override below.

Native Windows shells and macOS's bundled Bash 3.2 are not supported targets.

## Usage

Copy one hexadecimal digest, then run:

```bash
chmod +x clipboard_hash_compare.sh
./clipboard_hash_compare.sh ~/Downloads/file.iso
./clipboard_hash_compare.sh -- "file one.iso" "file two.iso"
./clipboard_hash_compare.sh --help
```

Use `--` before a filename named `--help` or `-h`. Symlinks to regular files are accepted; directories and special files are rejected.

Accepted clipboard formats:

- A bare hexadecimal digest, upper or lower case.
- A bare digest wrapped across lines (one hex fragment per line), or containing whitespace on a single line.
- One conventional checksum line: `digest  filename` or `digest *filename`, including GNU's escaped-record prefix.

The filename in a checksum line is ignored; the digest is compared with every selected file. Multiple checksum records are rejected. BSD/OpenSSL-style `SHA256 (filename) = digest`, algorithm labels, and entire checksum manifests are not supported; copy just the digest instead.

Example without accessing the clipboard or opening dialogs:

```bash
printf abc > sample.txt
CLIPBOARD_HASH_COMPARE_NO_GUI=1 \
CLIPBOARD_HASH_COMPARE_TEXT=900150983cd24fb0d6963f7d28e17f72 \
./clipboard_hash_compare.sh sample.txt
```

`CLIPBOARD_HASH_COMPARE_TEXT` overrides clipboard access even when set to an empty string. Set `CLIPBOARD_HASH_COMPARE_NO_GUI=1` to disable dialogs.

## Algorithms

| Hex characters | Candidates |
| --- | --- |
| 8 | CRC32, Adler32 |
| 16 | XXH64 (displayed as XXHash) |
| 32 | MD5 |
| 40 | SHA-1, RIPEMD-160 (displayed as RIPEMD) |
| 56 | SHA-224, SHA3-224 |
| 64 | SHA-256, SHA3-256, BLAKE2s-256, BLAKE3-256 |
| 96 | SHA-384, SHA3-384 |
| 128 | SHA-512, SHA3-512, BLAKE2b-512, WHIRLPOOL |

BLAKE3 uses the optional Python `blake3` module or `b3sum`. XXH64 uses the optional Python `xxhash` module or `xxhsum -H1` (seed zero). RIPEMD-160 and WHIRLPOOL depend on Python/OpenSSL availability; the script also tries the OpenSSL CLI and its legacy provider. Custom digest lengths, keyed hashes, XXH3, and XXH128 are not supported.

Optional Python modules can be installed in a virtual environment:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install blake3 xxhash
```

The script uses `python3` from `PATH`. A Thunar action must have the same environment to use these modules. Some Python builds disable algorithms; these are reported as unavailable, without bypassing the restriction. See the [Python hashlib documentation](https://docs.python.org/3/library/hashlib.html).

## Results and exit codes

| Code | Meaning |
| --- | --- |
| `0` | At least one file matched, with no errors or incomplete nonmatching files; also used by `--help`. |
| `1` | No files matched, and all candidate algorithms were checked. |
| `2` | Invalid input, clipboard/file/hash error, or a nonmatching file had unavailable candidate algorithms. |

**Success means any file matched, not that every file matched.** This preserves the original selection-oriented behavior. Errors take priority over matches. A matching file can still report unavailable algorithms without becoming an error; a nonmatching file with unavailable candidates is inconclusive and returns `2`.

## Thunar custom action

1. Put the script in a permanent location and make it executable.
2. In **Edit → Configure custom actions**, add an action named **Compare clipboard hash**.
3. Set its command to `bash "/absolute/path/clipboard_hash_compare.sh" %F`.
4. Under appearance conditions, enable the relevant file types and use `*` as the pattern.

Install Zenity to see results when Thunar launches the script without a terminal. Copy a digest, select files, then invoke the action from the context menu.

## Tests

Run under Linux or WSL; no live clipboard or GUI is needed:

```bash
bash test.sh
python3 test_regressions.py
```

The original algorithm smoke tests are included in `test.sh`. Regression tests exercise input errors, filenames, clipboard backend behavior, and optional-tool output validation. Real desktop clipboard access and dialogs still need testing in your own session.

## Review and fixes

- Keep terminal output when Zenity fails, and only attempt dialogs in a desktop session.
- Distinguish missing clipboard tools, failed reads, and empty clipboard content; add a WSL PowerShell fallback.
- Reject multiple checksum records instead of silently selecting the first.
- Handle unavailable hash constructors, including optional-module initialization failures.
- Read fallback-tool input through standard input to avoid filename escaping and option-parsing problems; explicitly select XXH64 and validate digest length.
- Avoid calculating CRC32 and Adler32 when they are not candidates.
- Add help, `--` handling, deterministic ASCII parsing, and LF line-ending rules for Git checkouts.

Remaining limitations: keep files unchanged while comparing (there is no snapshot or lock); very large selections can produce an unwieldy dialog; external clipboard readers have no timeout. A future explicit algorithm option would avoid inconclusive results when unrelated algorithms of the same length are missing. Hashes should come from a trusted source; a matching digest alone does not authenticate a download. MD5, SHA-1, and noncryptographic checksums are unsuitable for resisting deliberate tampering.
