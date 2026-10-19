# Architecture

A pure-Odin Odin compiler for Linux x86-64: no LLVM, no C toolchain, no libc. The compiler, its runtime startup (`_start`) and its syscall calls are all Odin. `AGENTS.md` governs how work here is done.

## Pipeline

`src/` holds one package per stage. Every package is imported as `import "oc:name"` through `-collection:oc=src`; the driver links them in this order:

```
syntax → check → lower → ir → sched → regalloc → amd64 → elf → link
```

| Package | Owns |
|---|---|
| `syntax` | tokenizer, index-based AST, parser |
| `check` | semantic records over immutable syntax: resolution, type checking, constants, polymorphism, `defer`, `context`; publishes the `Checked_Program` that lowering borrows |
| `lower` | `Checked_Program` to `ir.Module`: statements, expressions, ABI pieces, globals, the startup and entry-point glue |
| `ir` | Sea of Nodes graph (scalar values, pinned effects, one memory chain per function), builder, CFG, verifier, deterministic printer, interpreter |
| `sched` | global code motion: linear block layout order for the nodes of a function |
| `regalloc` | linear-scan register allocation over a data-only `Program`; knows nothing of `ir` or `amd64` |
| `amd64` | instruction selection, System V ABI and frame emission; encodes with `core:rexcode/isa/x86` |
| `elf` | ELF64 relocatable objects and static `ET_EXEC` executables |
| `link` | built-in static (and dynamic) linker: sections, symbols, relocations |
| `driver` | CLI, package collection, the pipeline, diagnostics, image writing |
| `odinc` | `main`; built by `mise run build` into `build/odinc` |

`types` is a library under `check`, `lower`, `amd64` and `driver`: canonical type descriptors, layout (size, align, offsets) and System V ABI classification. `core:mem/virtual` arenas back the stages that need them.

## Rules

- Deterministic output: the same input produces a byte-identical image, so no timestamps and no pointer-order dependence.
- Nodes and AST nodes are `distinct u32` handles into arrays, never pointers; node ids are assigned in creation order.
- The IR is verified after its builder finishes, and a schedule or machine function after each of its stages.
- Errors are values; the checker publishes only after its pools stop growing.
- Names, comments and test policy follow `AGENTS.md`, which overrides the `odin-maintainer` skill on comment and test volume.

## Running it

```
mise run build            # build odinc into build/odinc
mise run check [package]  # check one package, or all of them
mise run test  [package]  # run the package's tests
```

`odinc <file-or-dir> -out:<executable>` compiles an Odin main to a static executable; `odinc <file> -histogram` prints the IR histogram instead.

## Design history

The design documents that used to sit here and the research notes, except `docs/research/01-gingerbill-vision.md`, are archived under `docs/archive/` (research under `docs/archive/research/`). They record the intent behind this architecture; the source is the record of what is implemented. Do not load the archive by default.
