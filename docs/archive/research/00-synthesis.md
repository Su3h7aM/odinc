# Synthesis: a pure-Odin compiler for Odin (Linux x64)

Sources: 01-gingerbill-vision.md, 02-backend-ir-landscape.md, 03-existing-compiler-map.md. Unverified claims in those reports (X read via mirror, Tilde removal details) should be checked against the originals before we quote them.

## What Ginger Bill wants, and why

- An alternative backend that is faster for development builds and uses less memory than LLVM. He floated a Sea of Nodes IR. He said "write our own backend" for full control (Mar 2026), then hedged that it may never happen (Oct 2026).
- Motivation: LLVM dev-build speed, memory, dependency size, bugs. Release-quality output is not the target.
- No committed roadmap exists. We are building toward the stated vision, not an official plan.

## Findings that shape the design

1. The existing compiler (C++, ~163k lines, unity build) has LLVM as its only code generator. The seam for a new backend is `lb_init_generator` / `lb_generate_code` / `linker_stage` (`main.cpp:4941-4957`). There is no Tilde code left to reuse.
2. Sea of Nodes has a poor track record for a solo, correctness-first effort (V8 left it in 2025: effect-chain bugs, cache cost, hard debugging). Cranelift keeps a CFG and floats only pure ops.
3. Dev-build speed comes mostly from skipping LLVM, a simple IR, linear-scan register allocation, and emitting ELF directly. It does not require a clever IR.

## Proposed principles

- Correctness over cleverness. Every pass has a text dump and a verifier. The IR has an interpreter for differential testing against the LLVM-built `odin`.
- Start with a CFG IR in SSA form with block parameters. Keep the IR design open to a later floating-pure-ops layer (Cranelift style). Treat Sea of Nodes as a hypothesis to test after v1, not a v1 requirement.
- Written in Odin, following core-library conventions: explicit allocators (arenas per phase), no hidden globals, `core:` packages where they fit, no C dependencies.
- Linux x64 only, SysV ABI. Emit ELF `.o` first, then a built-in static linker. No external assembler or linker in the end state.
- Reuse Odin's own design: `context` and allocators, tagged unions for IR nodes, `soa` layouts for hot tables, parallelism by package.

## Staging

0. Decide the frontend question (see below).
1. IR definition, verifier, printer, interpreter.
2. Lowering for a core subset (ints, control flow, calls, structs).
3. x64 instruction selection, linear-scan register allocation, ELF `.o` emitter.
4. Odin features in order: multiple returns, `context`, `defer`, slices and strings, unions and `any`, RTTI, polymorphism (done in the checker), maps and dynamic arrays via `base:runtime`.
5. Built-in linker, then DWARF, then optimizations (peephole, DCE, SCCP, GVN, inlining).

## Open decisions for you

1. **Frontend.** Does the pure-Odin compiler include its own tokenizer, parser and checker (~100k+ lines to port), or consume the existing C++ checker's output at first? Odin already ships `core:odin/parser` and `core:odin/ast`, but they do not include a type checker.
2. **IR choice.** Confirm a CFG SSA IR for v1, with Sea of Nodes as a later experiment, or insist on Sea of Nodes from the start.
3. **Build target.** Dev builds only, or eventually release performance too.
4. **Bootstrap.** Is the first milestone "compile a hello world with `base:runtime`", or "compile the compiler itself"?
5. **`/refs/rfcs/linux`.** It holds kernel docs and man pages, not RFCs. I'll use it as the syscall and ELF reference unless you meant something else.
