# msys2-runtime-patch

One-command patch tool for the MSYS2 `add_item` fatal error that kills
concurrent `bash.exe` / `sh.exe` startup on Windows (seen heavily with
Git for Windows + tools that spawn many short-lived shells, e.g. Claude
Code, IDE integrations, CI agents, and antivirus-injected hosts).

```
sh.exe: *** fatal error - add_item ("\??\C:\Program Files\Git", "/", ...) failed, errno 1
```

This repo builds patched `msys-2.0.dll` binaries from the exact upstream
source baseline your Git for Windows ships with, and provides
`Apply-Patch.ps1` / `Restore-Patch.ps1` to install and roll back safely.

## Root cause (short version)

`msys-2.0.dll` initializes a per-user shared memory region exactly once,
guarded by a 15-second spinlock (`SPINLOCK_WAIT`, `winsup/cygwin/shared.cc`).
If the initializing process is stalled inside the critical section longer
than 15s — slow domain account lookups, antivirus DLL injection slowing
startup 30-300x, or the initializer being killed mid-init — waiting
processes give up, proceed as the initializer, and run
`mountinfo.init()` a second time against an already-populated mount
table. `create_root_entry()` then re-adds the immutable `/` entry,
`add_item()` returns `EPERM`, and `api_fatal()` aborts every affected
process. A second death mode exists: late starters attach to the
half-initialized shared section (`user shared version FFFFFFFF`) and
crash with an access violation. Known since 2015; still unfixed
upstream.

References:

- [msys2/msys2-runtime#333](https://github.com/msys2/msys2-runtime/pull/333) — patch PR (open, not merged)
- [git-for-windows/git#6368](https://github.com/git-for-windows/git/issues/6368) — source-level analysis of the race
- [git-for-windows/git#1135](https://github.com/git-for-windows/git/issues/1135) — maintainer's classification ("competing MSYS2 processes without a common parent")
- [anthropics/claude-code#30165](https://github.com/anthropics/claude-code/issues/30165) — Claude Code users hitting this
- [msys2-users mailing list, 2016](https://sourceforge.net/p/msys2/mailman/message/35070454/) — first mechanism description

## Patches included

| Patch | Variant | Default | Source |
|---|---|---|---|
| `patches/0001-...` | `create_root_entry` passes `MOUNT_OVERRIDE` so re-adding `/` overwrites instead of failing | yes | msys2-runtime#333 (ilude) |
| `patches/0002-...` | `add_item` treats a byte-identical duplicate immutable entry as a no-op | alt | primeinc fork `fix/add-item-idempotent-root` |

Both address the same race; variant 2 additionally preserves the
`root_idx` re-init path explicitly. Build job produces one DLL per
variant; `Apply-Patch.ps1 -Variant Alt` installs the alternative.

## Supported baselines

The tool matches on your installed `msys-2.0.dll` **ProductVersion**
(e.g. `3.6.7-fb42d71358dd896ab324c52970f7d03f9ab0dfe5`), not on file
bytes — the version string is embedded from the exact source commit via
`--with-msys2-runtime-commit` and is a stable fingerprint.

| Git for Windows | msys2-runtime (Cygwin) | baseline id |
|---|---|---|
| 2.54.0.windows.1 | 3.6.7 @ `fb42d71358dd896ab324c52970f7d03f9ab0dfe5` | `3.6.7-fb42d713` |

Anything else: the script refuses to touch your installation and prints
this table. To add a baseline, extend `baselines.json` and the build
matrix (PRs welcome).

## Usage

```powershell
# apply (auto-elevates; backs up the original DLL first)
.\Apply-Patch.ps1                    # default variant
.\Apply-Patch.ps1 -Variant Alt       # alternative variant
.\Apply-Patch.ps1 -GitRoot "D:\Program Files\Git"

# roll back to the original DLL
.\Restore-Patch.ps1
```

What Apply-Patch.ps1 does, in order:

1. Locates your Git for Windows install (parameter, registry, or common paths).
2. Reads `usr\bin\msys-2.0.dll` ProductVersion; refuses if not in `baselines.json`.
3. Kills running processes that have `msys-2.0.dll` loaded (lists them first, asks for confirmation).
4. Downloads the matching patched DLL from this repo's Releases, verifies its SHA256.
5. Backs up your original as `msys-2.0.dll.orig` (kept; Restore uses it).
6. Replaces the DLL, then runs `sh -c "exit 0"` probes (serial + burst) to verify.

## Warnings — read before applying

- **Unsigned binary.** The patched DLL is built on GitHub Actions and has
  no Authenticode signature. SmartScreen, or an enterprise AV policy
  (e.g. Symantec ADC injecting `sysfer.dll`), may flag or slow it. On
  hosts where AV injection *causes* the race, exclusion of the Git
  install directory from injection/scanning is the real fix — this patch
  removes the runtime's fatal reaction to the stall, it does not remove
  the stall.
- **Updates overwrite it.** Upgrading Git for Windows replaces
  `msys-2.0.dll`; re-run Apply-Patch (the version check will tell you
  whether your new baseline is supported).
- **Not upstream.** The underlying fix is not merged upstream. If
  msys2-runtime ships an official fix in a future Cygwin release,
  upgrade Git for Windows instead of patching.
- **License.** `msys-2.0.dll` is GPL-3.0-or-later. Releases ship the
  exact source (commit + patches) they were built from; see the
  `source-info.json` asset in each release.

## Building from source (what CI does)

`scripts/build.sh` runs inside an MSYS2 shell (CI: `windows-latest` +
[msys2/setup-msys2](https://github.com/msys2/setup-msys2)):

1. Checks out the official `msys2-runtime` PKGBUILD pinned to the
   baseline's Cygwin rebase (e.g. `MSYS2-packages@18d02e2d65ce` for
   3.6.7, so the msys2 patch set matches the era).
2. Points `msys2-runtime.commit` at the baseline commit so the built DLL
   reports the same ProductVersion as the DLL being replaced.
3. Applies the fix patch from `patches/`.
4. `makepkg` → uploads `msys-2.0.dll` + SHA256 + source manifest to the
   release tagged for that baseline.

## Status

- Upstream fix: **not merged** (msys2-runtime#333 open; nothing on
  cygwin-patches as of 2026-10).
- This repo: v1 supports the single baseline above; more on request.

## Acknowledgements

- ilude (Mike Glenn) — the #333 patch and the original concurrent-startup fix writeup
- Ross Moravec — the source-level analysis in git-for-windows#6368
- primeinc — the alternative no-op variant
