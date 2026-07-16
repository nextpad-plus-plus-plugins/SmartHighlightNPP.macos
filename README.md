# SmartHighlightNPP (macOS)

SmartHighlight plugin for Nextpad++ (macOS):

- Dockable highlight panel (10 styles, persisted)
- Cisco log parsing — Q.850 cause codes, DTMF blocks, X.509 / SAML decoding
- Nested archive extractor

Forked from [tonynupe/SmartHighlightNPP](https://github.com/tonynupe/SmartHighlightNPP)
at tag `1.0.4` (commit `3446331`). The first commit here is that source verbatim,
so `git log` shows exactly what changed and why.

## Naming

The folder name and the dylib name are **not** independent. `NppPluginManager.mm`
derives the dylib name from the directory name and skips the plugin silently if
they disagree, so this ships as:

```
SmartHighlightNPP/
└── SmartHighlightNPP.dylib
```

Upstream shipped `CiscoCollab/CiscoCollab.dylib` while its catalog entry declared
`folder-name: SmartHighlight`, which is why it could not install. There is only
one dylib — it exports the five plugin entry points and is the whole plugin. It
is not a library, and nothing else links against it; `CiscoCollab.dylib` was just
what the author's hand-run build happened to emit.

The plugin calls itself **SmartHighlight** in the Plugins menu and panel title
(`getName()`), which is the human-facing name; `folder-name` is the package slug.
The Cisco features — Q.850 / DTMF / X.509 parsing on the cursor line, and the
CiscoCollab UDL — are a specialist layer on a general-purpose highlighter, so the
catalog `display-name` is the right place to carry that context.

## Build

```sh
./build.sh              # build + verify + package
./build.sh --no-zip     # build + verify only
```

Universal (arm64 + x86_64), deployment target 10.13, no dependencies beyond the
system frameworks. `build.sh` fails the build unless the output is universal,
exports exactly the five entry points, has no non-system dependencies, carries a
real `current_version`, and zips as `<folder>/<folder>.dylib`.

## Test

```sh
./test/run.sh           # 28 assertions, ~5s
```

The harness includes the translation unit directly (the helpers are `static`) and
is compiled with a 1 MB decompression ceiling and a depth limit of 3 so the guards
can be exercised cheaply. The shipped build uses 2 GB / 50.

## Changes from upstream 1.0.4

| Fix | Why |
|---|---|
| Archives go to the **Trash**, not `removeItemAtPath:` | The archive the user picked was unlinked outright after extraction — unrecoverable, with nothing in the open panel warning them. It may be their only copy. |
| **gzip output streamed to disk, capped at 2 GB** | `gzip -dc` was read fully into one `NSData`. Measured ~1029:1 expansion (203 KB → 200 MB), and the plugin shares the editor's address space, so a hostile `.gz` OOM'd the editor and took unsaved tabs with it. |
| **Nested recursion bounded to 50** | The walk had no depth limit at all; an archive containing itself recursed until the disk filled. 50 matches the Python tool this was ported from. |
| **`ccRunTask` / `ccRunTaskCapture` drain their pipes** | `standardOutput` was an undrained `NSPipe`: any tool emitting more than the 64 KB pipe buffer (7z prints a line per entry) blocked forever and `waitUntilExit` never returned. |
| **Config falls back to Application Support** | The fallback named `~/.notepad++/plugins/Config`, a pre-rebrand path the host abandoned; writing there silently re-created a dead directory. |
| **`current_version` stamped** | Was `0.0.0`, so Plugins Admin could not report the installed version. |
| Build script + test harness added | Upstream had neither, so the released binary could not be reproduced from — or checked against — its source. |

Not changed: the plugin's behaviour, UI, parsing, and highlighting are upstream's.
Extraction still deletes intermediate archives it unpacked — those now go to the
Trash too.

## Security review

Reviewed before forking. No network capability whatsoever: no network APIs in the
source, no network symbols or frameworks in the binary, and no URL, domain, IP, or
email in any of its bytes. No shell invocation (subprocesses use argv arrays and
absolute paths), no dynamic code loading, no obfuscation. Path traversal is
contained — `tar` refuses `..` and symlink members, `ditto` normalises them into
the destination, and `NSDirectoryEnumerator` does not follow directory symlinks.

## License

⚠️ **Unresolved.** Upstream ships no LICENSE and no copyright notice in any file,
which means no rights are granted by default. `NppPluginInterfaceMac.h` is derived
from the Nextpad++ host (GPL). This needs the author to state a license before the
plugin is distributed — it is deliberately not decided here, since the copyright
is his, not ours.
