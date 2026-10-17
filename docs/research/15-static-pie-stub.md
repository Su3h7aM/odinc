# Static-PIE self-relocation stub

References: musl `ldso/dlstart.c` (`_dlstart_c`), `crt/rcrt1.c`, glibc
`elf/dl-reloc-static-pie.c`; zig `lib/std/pie.zig` (`relocate`).

## Why self-relocation is needed

The Linux kernel maps an `ET_DYN` without `PT_INTERP` at a randomized
base but does not process its relocations. A static-PIE executable
therefore carries a `.rela.dyn` of `R_X86_64_RELATIVE` entries and
applies them itself before reaching `_start`'s body.

## Linker contract

The linker emits, for a static-pie image:

- `ET_DYN`, base link address `0`.
- A `PT_DYNAMIC` with `DT_RELA`, `DT_RELASZ`, `DT_RELAENT`, and
  `DT_FLAGS`/`DT_FLAGS_1` set to `DF_BIND_NOW`/`DF_1_NOW`.
- `.rela.dyn` entries of kind `R_X86_64_RELATIVE` whose `r_offset` is
  the image virtual address of each field to fix up and whose
  `r_addend` is the link-time target address.
- Linker-defined symbols the stub reads:
  - `_DYNAMIC` (hidden, weak) — address of the `Elf64_Dyn` array.
  - `__rela_start` / `__rela_end` — bounds of `.rela.dyn`.
  - `__ehdr_start` — first byte of the image in memory.

## Stub algorithm (x86-64)

```
1. base = _DYNAMIC - _DYNAMIC_linkaddr   (link-time _DYNAMIC address is
   the linked value of the symbol; at runtime the symbol resolves to the
   loaded address, so the difference is the load delta).
2. for each Elf64_Rela in [__rela_start, __rela_end):
       if r_type == R_X86_64_RELATIVE:
           *(base + r_offset) = base + r_addend
3. jump to _start body
```

The stub runs before any global data is read, so it must use only
PC-relative addressing and must not touch the GOT.

## Test plan

- Unit test in `src/link` builds a static-pie image from a hand-assembled
  object, runs it, expects exit code 7.
- Determinism test: link twice, byte-identical.
- `llvm-readelf -d/-r` confirms `DYN`, `RELATIVE`, no `INTERP`.
