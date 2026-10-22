# Architecture

A pure-Odin Odin compiler for Linux x86-64: no LLVM, no C toolchain, no libc. The compiler, its runtime startup (`_start`) and its syscall calls are all Odin. `AGENTS.md` governs how work here is done.

## Pipeline

`src/` holds one package per stage. Every package is imported as `import "oc:name"` through `--collection=oc=src`; the driver links them in this order:

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

The declared target baseline defaults to x86-64-v1: only x87, CX8, CMOV, MMX, FXSR, SSE and SSE2 are assumed present. `--mcpu` raises it to x86-64-v2, -v3 or -v4.

## Rules

- Deterministic output: the same input produces a byte-identical image, so no timestamps and no pointer-order dependence.
- Nodes and AST nodes are `distinct u32` handles into arrays, never pointers; node ids are assigned in creation order.
- The IR is verified after its builder finishes, and a schedule or machine function after each of its stages.
- Errors are values; the checker publishes only after its pools stop growing.
- Names, comments and test policy follow `AGENTS.md`, which overrides the `odin-maintainer` skill on comment and test volume.

## What the official compiler is for

The official LLVM compiler defines *behavior*, never *structure*. What we reproduce is its observable contract:
which programs it accepts and which it rejects, every diagnostic that a program must produce, the values the
compiled program computes, its stdout and its exit code. Nothing about how it is implemented is part of that
contract.

So the official sources are read to answer "what should happen", and then the answer is implemented the way this
architecture implements things — Sea of Nodes, one memory chain, nodes as `distinct u32` handles, `lower` building
`ir` rather than emitting instructions. Copying an upstream arrangement of passes, a value representation, a
backend's denormalization scheme or its block ordering would produce a Frankenstein: an LLVM-shaped compiler
wearing an Odin front end, which is neither what this repository is nor faster than what it replaces.

The failure mode to watch for is a change that is *only* justifiable by "upstream does it this way". If the
justification is not a behavior difference, the change belongs in this compiler's own vocabulary.

Useful references, in the order `AGENTS.md` gives for resolving disagreements:

- `refs/Odin-upstream/src` — the official checker and LLVM backend. Authoritative on *what* the language does.
  The checker is the stronger reference: it is the source of the semantics we must match, and it is not
  LLVM-shaped.
- `refs/odin-tilde-backend/src` — Yasser Arguelles Snape's Tilde Backend, the Sea-of-Nodes backend Ginger Bill
  adopted in 2023 before removing it in 2026 (PR #6483). It shares our family of IR and is the closest existing
  work to this backend's design, so it is the right place to look for how a Sea-of-Nodes backend handles
  lowering, effect pinning, block placement and instruction selection.
- `docs/research/01-gingerbill-vision.md` — what Ginger Bill actually said, with dates, links and quotes, and an
  explicit list of what is settled and what is still open.

Tilde is a *reference for the same problem*, not a template. It is C, it targets several backends, and it carries
the baggage of being embedded in Cuik. Read its reasoning; write this compiler's Odin.

## Running it

```
mise run build            # build odinc into build/odinc
mise run check [package]  # check one package, or all of them
mise run test  [package]  # run the package's tests
```

`odinc build <file-or-directory> --output <executable>` compiles an Odin main to a static executable. `odinc check <file-or-directory>` parses and type-checks without generating code or an output file; `--no-entry-point` permits a package without `main`. Collections and definitions use `--collection/-c` and `--define/-d`.

## Design history

The design documents that used to sit here and the research notes, except `docs/research/01-gingerbill-vision.md`, are archived under `docs/archive/` (research under `docs/archive/research/`). They record the intent behind this architecture; the source is the record of what is implemented. Do not load the archive by default.
