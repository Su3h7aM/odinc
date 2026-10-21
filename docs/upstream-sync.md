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

Vendor binaries are not synced: the vendor tree is imported as source only, and the excluded patterns keep platform binaries out.
