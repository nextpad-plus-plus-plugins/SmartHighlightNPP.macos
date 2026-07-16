# SmartHighlightNPP (macOS)

SmartHighlight plugin for Nextpad++ (macOS):

- Dockable highlight panel (10 styles, persisted)
- Cisco log parsing — Q.850 cause codes, DTMF blocks, X.509 / SAML decoding
- Nested archive extractor

## Credits

Written by **Anthony Nunez** ([@tonynupe](https://github.com/tonynupe)) — original:
[tonynupe/SmartHighlightNPP](https://github.com/tonynupe/SmartHighlightNPP). It is a
port of his Sublime Text package [tonynupe/CiscoCollab](https://github.com/tonynupe/CiscoCollab).
All of the plugin's functionality is his work.

This fork exists so the artifact users download is built from source that can be
reviewed and reproduced, and to fix the issues listed below. Forked at tag `1.0.4`
(commit `3446331`); the first commit here is that source **verbatim**, so `git log`
shows exactly what was changed and why.

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

## Note: the CiscoCollab UDL could live in the UDL index instead

"Install/Update Cisco Language (UDL)" writes an embedded `CiscoCollab.xml` straight
into `userDefineLangs/`, bypassing UDL Admin and the [nppUDLList](https://github.com/nextpad-plus-plus/nppUDLList)
index entirely. It is a candidate to be pulled into that index instead.

The index already contains a **mechanically converted** copy of the same language:
`UDLs-Sublime/Cisco.xml`, produced by `tools/sublime2udl.py` from the author's
Sublime package. Both have the same 28 keyword groups and the same extension list
(`cfg txt gzo log`), so they share a lineage — but that converted copy is **not
listed in `udl-list.json`**, and it is the weaker of the two:

```
Comments   plugin  : 00! 01 02 03 04
           Cisco.xml: 00  01 02 03 04
```

The plugin's hand-tuned version declares `!` as the line-comment character — the
comment marker in Cisco IOS configs — which the conversion dropped, along with the
number prefixes (`+-[({<`). 13 of 28 groups are identical; the other 15 differ, and
in every case the plugin's is the more complete.

So the plugin's UDL is worth publishing into `udl-list.json` in its own right (it
would improve the existing `Cisco.xml`). If it is, this plugin could drop the UDL
writer and its menu item, and let UDL Admin own installation, updates, dark-mode
handling and Global Override. That is the author's call — the UDL is his work.

## Requirements

Nextpad++ **1.0.8 or newer**. "Install/Update Cisco Language (UDL)" writes to
`~/Library/Application Support/Nextpad++/userDefineLangs`, which is only the host's
config directory from 1.0.8 onward (PR #211); on 1.0.7 that feature would write to
a path the host does not read.

## License

⚠️ **Unresolved — pending the author.** The upstream repository ships no LICENSE
and carries no copyright notice in any file, so no rights are formally granted.
Copyright in this code is Anthony Nunez's, not this project's, and no license is
asserted here on his behalf. `NppPluginInterfaceMac.h` derives from the Nextpad++
host (GPL). A license statement from the author is being requested; this note stays
until he provides one.
