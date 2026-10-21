# Upstream sync

last synced upstream: 779c8c0a4778f994389e2a681ffc7b3cbd6c1f65

This repository mirrors `base/`, `core/`, `vendor/` and `tests/` from the Odin upstream. Our copy carries local adaptations (native heap allocator, no-libc Linux runtime, raw-syscall `core:sys/linux`, `core:os`, `core:nbio`). Those files are pinned, so a sync never overwrites them silently.

## Tools

- `mise run sync-upstream -- --base <commit> --upstream <commit> [--only <prefix>] [--out plan.tsv]` prints a three-way plan per changed path. It is a dry run; add `--apply` to write. Apply refuses while any path is `CONFLICT`; `--force` overrides that.
- `mise run pin-check` compares the pinned files with `docs/upstream-sync/pinned-manifest.tsv`. It exits non-zero on any change, missing file, or deleted file that must stay absent.
- `mise run pin-check -- --update` rewrites the manifest. Run it in the same commit that edits a pinned file.

Inputs in `docs/upstream-sync/`:

- `pinned-paths.txt`: paths that are never merged automatically. A change on both sides becomes `HOLD`, for a person to decide.
- `pinned-manifest.tsv`: blob hash of each pinned path; `-` means the path must stay deleted.
- `vendor-exclude.txt`: glob patterns for non-Linux binaries that are not mirrored.

The upstream checkout is read from `UPSTREAM_REPO` (default `~/Projects/refs/Odin-upstream`). `SYNC_ROOT` selects another tree to sync.

## Plan actions

- `TAKE`: ours equals base; upstream's version is copied (or the file removed if upstream deleted it).
- `ALREADY`: ours already equals upstream, or the merge changes nothing.
- `MERGE`: both sides changed an unpinned path and `git merge-file` is clean.
- `HOLD`: both sides changed a pinned path, or the path exists on one side only.
- `CONFLICT`: `git merge-file` left conflict markers. Resolve by hand before applying.
- `EXCLUDED`: matches `vendor-exclude.txt`.

Paths upstream did not change are never touched, so local additions, deletions and rewrites survive.

A `GUARD` line flags a new libc reference (`foreign import "system:c|dl|pthread|m|rt"` or a libc `link_name`) in a base/ or core/ file that Linux may build. Read every `GUARD`.

## Procedure

1. Fetch the upstream checkout.
2. Dry run with `--base` set to the commit in the first line of this file, `--upstream` set to the new commit.
3. Read every row that is not `ALREADY`, and every `GUARD`.
4. Resolve each `HOLD` by hand, by hunk. For the allocator and the no-libc stack, keep our behavior.
5. Apply. Make base/ and core/ read-only again (the tool does this).
6. Run the acceptance checks: `mise run pin-check`, `mise run check`, `mise run test`, and a dry run that shows no `CONFLICT`.
7. Make one commit with the synced files, the updated manifest if a pinned file changed, and the new commit in the first line of this file.

## vendor/

`vendor/` is a read-only mirror of upstream `vendor/` at `779c8c0a` (the committed blobs; Git LFS pointers resolved to their content). It holds 1249 files, 41,321,279 bytes (about 39 MiB), and 118 directories. It keeps 13 Linux x86-64 binaries: `box3d/lib/linux-amd64/libbox3d.a`, `lua/5.1` to `lua/5.4` `linux/liblua5x.a` and `.so` (8 files), and `raylib/linux/libraylib.a`, `libraylib.so.600`, `libraygui.a`, `libraygui.so`. Every other binary is excluded by `docs/upstream-sync/vendor-exclude.txt`: Windows, macOS, wasm and `linux-arm64`. Copied files are read-only (files 444, directories 555), like `base/` and `core/`. `mise run fmt` formats `src/` only, so `vendor/` is never formatted.

Files above 1 MiB (jj's default `snapshot.max-new-file-size`; neither the repo nor the user jj config sets it): `vendor/miniaudio/src/miniaudio.h` (4.1 MB), `vendor/raylib/linux/libraylib.a` (2.9 MB), `vendor/raylib/linux/libraylib.so.600` (2.1 MB), `vendor/kb_text_shape/src/kb_text_shape.h` (1.7 MB), `vendor/box3d/lib/linux-amd64/libbox3d.a` (1.6 MB), `vendor/vulkan/_gen/vulkan_core.h` (1.4 MB). jj leaves them untracked until the limit is raised.
