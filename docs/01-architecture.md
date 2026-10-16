# Architecture and foundation plan

Direction (from the project owner): a pure-Odin Odin compiler, built with our fork (`/home/su3h7am/Projects/Odin/odin`), Linux x64 only. No incremental "always working compiler" path and no reuse of the C++ compiler. We build the foundation components first and integrate them later. Correctness and determinism come first. Performance comes from a data-oriented design, not from optimization passes (no CPU-feature tuning like AVX2 yet).

## IR decision: Sea of Nodes

Evidence on Ginger Bill's position (docs/research/01): he said he would "even just change the approach too to be Sea of Nodes based rather than the approach LLVM currently uses". It was an aside in a hedged thread, not a design document. We still follow it, as instructed, and keep the V8 findings (docs/research/02) as a list of risks to design against:

- Effect and control chains are error-prone: model memory and side effects as explicit state edges (Click's Simple tutorial style), and write a verifier that checks them.
- Poor cache behaviour: nodes live in struct-of-arrays storage addressed by `distinct u32` handles, not by pointers. Edges are index lists in one arena per function.
- Hard to debug: a deterministic text dump of the graph, plus a graph-to-text round trip, from the first commit.
- Scheduling is hard: a global scheduler (GCM) is a separate, well-tested package.
- Determinism: node ids are assigned in creation order, no hashing by address, no iteration over maps whose order matters.

Odin types are used for the IR itself: `distinct u32` node and type handles, a `Node_Kind` enum, `#soa` or hand-rolled SOA arrays for hot fields, `bit_set` for flags, tagged unions for payloads. No pointer-linked nodes.

## Package layout

All packages sit under `src/` and are imported with `-collection:oc=src`, as `import "oc:name"`. Tests live beside the source in `*_test.odin`.

| Package | Purpose | Depends on |
|---|---|---|
| `support` | arenas, interned strings, source files and positions, diagnostics | core only |
| `syntax` | tokenizer, AST (index based), parser | support |
| `types` | semantic type store, type interning, layout (size/align, SysV) | support |
| `check` | name resolution, type checking, constants, polymorphism, `defer`/`context` semantics | syntax, types |
| `ir` | Sea of Nodes graph, builder, verifier, printer | support, types |
| `sched` | global code motion, scheduling to linear blocks | ir |
| `x64` | instruction encoder, instruction selection, register allocation | ir, sched |
| `elf` | ELF64 relocatable and executable writer, symbols, relocations | support |
| `link` | built-in static linker | elf |
| `driver` | CLI, package loading, pipeline, deterministic output | all |

## Build and check commands

```
ODIN=/home/su3h7am/Projects/Odin/odin
$ODIN check src/<pkg> -no-entry-point -collection:oc=src -vet -strict-style
$ODIN test  src/<pkg> -collection:oc=src -vet -strict-style
```

## Code rules (apply to every component)

- Follow the `odin-maintainer` skill: explicit allocators and arenas, `snake_case` procs, `Ada_Case` types, errors as values, no hidden allocation, zero value inert, `distinct` handles, `bit_set` flags, doc comment above each public declaration.
- Deterministic output: same input gives byte-identical output. No timestamps, no pointer-order dependence.
- Every package has tests that run in CI-style `odin test`, and a `doc.odin`.
- No speculative features. Implement what the foundation needs.

## Foundation order

Wave 1 (independent, no cross-dependencies): `support`, `elf`, `x64` encoder, `syntax` tokenizer.
Wave 2: `syntax` AST and parser, `types`, `ir` core graph with verifier and printer.
Wave 3: `check`, `sched`, instruction selection, register allocation.
Wave 4: `link`, `driver`, integration, first end-to-end milestone.
