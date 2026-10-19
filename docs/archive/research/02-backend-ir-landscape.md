# Backend IR Landscape: Sea of Nodes, Tilde, Cranelift/ISLE, QBE, LLVM

**Status:** research note
**Scope:** IR/small-backend designs relevant to a from-scratch, correctness-first x86-64 Linux Odin compiler that emits machine code directly.
**Method:** web research only. Claims are sourced. Items that are second-hand, anecdotal, or my own estimates are explicitly marked **[uncertain]**. Dates reflect the sources as published/accessed (see [Sources](#sources)).

> Note on the task framing: the V8 move away from Sea of Nodes is often dated "2023". The migration effort began around 2022 ("almost 3 years" before publication) and the blog post describing it, *Land ahoy: leaving the Sea of Nodes*, was published **25 March 2025**. Treat "2023" as when the internal effort got underway, not the publication date. See [Land ahoy](#sources).

---

## 1. Cliff Click's Sea of Nodes (SoN)

### 1.1 Origin and definition

Sea of Nodes was introduced by Cliff Click in his 1995 Rice PhD thesis *Combining Analyses, Combining Optimizations*, and in the co-authored paper Click & Paleczny, *A Simple Graph-Based Intermediate Representation* (IR '95, SIGPLAN Not. 30(3):35–49, DOI 10.1145/202530.202534).

The defining property, per Wikipedia's summary of the primary sources, is a graph representation of an **SSA** program that **combines data flow and control flow and relaxes control flow from a total order to a partial order**, keeping only the orderings required by data flow. Concretely:

- **Nodes are individual instructions** (not basic blocks, as in a CFG).
- **Value edges** represent uses.
- **Control edges** impose ordering on control nodes (`branch`, `goto`, `return`) that have no value dependency ordering.
- **Effect edges** impose ordering on side-effecting operations (loads/stores/calls) so they neither float randomly nor are pinned to the full control chain. The effect chain typically splits on branches and merges where control merges.

Because a node has no fixed position in a total order, the IR must **schedule** the graph back into a linear order before codegen. This is the origin of *Global Code Motion / Global Value Numbering* (Click, PLDI '95, DOI 10.1145/207110.207154).

### 1.2 Where it is used

SoN is/was used in HotSpot C2 (JVM), GraalVM, libFirm, and — until recently — V8's TurboFan. (Wikipedia; Demange et al., *Semantic reasoning about the sea of nodes*, CC 2018.)

### 1.3 The `SeaOfNodes/Simple` tutorial

`github.com/SeaOfNodes/Simple` is a self-described showcase for the SoN IR: a small Java-ish, strongly-typed, object-oriented language ("Simple") compiled to x86-64, RISC-V, and ARM64, AOT but with an eye to JIT. 922 stars, Apache-2.0 at time of access. It is organized as 25 self-sufficient chapters, each a complete compiler of a growing language subset, with commentary on SoN.

Most relevant chapters for a from-scratch backend:

| Chapter | Topic |
|---|---|
| 5–8 | `if`, `while`, eager and lazy phi, `break`/`continue` |
| 9 | GVN, iterative peepholes to fixpoint, worklists |
| 10–12 | Memory as an SSA value; lazy memory partitioning (`MemMerge`, `MemPhi`, `BulkMemPhi`); references |
| 13 | **Global Code Motion — scheduling** |
| 19 | Instruction selection and portable compilation |
| 20 | **Graph-coloring register allocation** |
| 21 | **Instruction encodings & ELF** |
| 22 | A complete Hello, World! |
| 24 | Chained conditionals and SCCP |
| 25 | Modules, separate compilation, SSA construction with incomplete types |

Note the design: chapters 1–18 are essentially an SO N front/middle end, and the backend does not appear until chapter 19. There is also a Java evaluator of the SoN IR (from chapter 8) so programs can be executed long before machine code exists — a useful correctness technique (see §8).

The repo contains `ASimpleReply.md` (a reply document, presumably to critiques of SoN) which is worth reading directly; I did not analyze its contents here. **[uncertain: contents not read]**

### 1.4 Known problems (the V8 experience)

The most detailed public post-mortem is V8's *Land ahoy: leaving the Sea of Nodes* (Darius Mercadier, 25 Mar 2025). V8 replaced SoN with a CFG IR named **Turboshaft**, and its JS front end with a CFG-based IR (Maglev). Summary of the problems V8 enumerates, with their specific numbers where given:

1. **Hard to inspect/understand.** A moderately sized function becomes "a messy soup of nodes"; the IR is farther from both source and assembly than a CFG. They show a `concat` loop whose SoN graph is unreadable next to the CFG version.
2. **Almost everything ends up on the effect/control chain.** In JS graphs, memory ops need both an effect input and a control input (checks/bound checks), so "**SoN is just CFG where pure nodes are floating**." The effect chain mirrors the control chain in practice.
3. **Memory ops do not float easily**: to sink loads into branches you must prove no aliasing side effects between them — "extremely similar" work to doing it on a CFG.
4. **Managing effect/control chains manually is error-prone.** They cite a real bug where three effect chains were conflated (crbug.com/41470351, fixed in crrev.com/c/1749902).
5. **The scheduler is too complex.** CSE can deduplicate two divisions into one, then the scheduler must *re-duplicate* them to avoid computing on paths that don't need them.
6. **Finding a good visitation order is hard.** SoN peepholes must walk *upward* from returns through value/effect/control edges — "about the worst visitation order you could get." Measured: **nodes are changed only once every ~20 visits**. Pure roots have no entry point.
7. **State tracking is hard and expensive.** Load elimination tracks state along the graph; hard to know when state can die. TurboFan's SoN load elimination **bails out on large graphs** to bound time/memory. Their new CFG load elimination is measured **up to 190× faster** with far less memory.
8. **Cache unfriendliness.** Phases mutate the graph in place with new nodes scattered in memory. SoN shows **~3× more L1 dcache misses on average, up to 7× in some phases**, estimated at **up to ~5% of compile time** (author calls this "handwavy").
9. **Control-flow-dependent typing is limited.** A `CheckedAdd` that is pure floats freely, so you cannot eliminate the overflow check using the branch's known range until after scheduling (i.e., after you already have a CFG). TurboFan patches this by putting a control input on `CheckedAdd` — "a.k.a., going back to a CFG."
10. **Propagating deadness is hard** (must patch both control and effect chains).
11. **Hard to introduce control flow during lowerings** (e.g. lowering a pure `Int32Max` to an if/else); such lowerings are deferred to the scheduling phase, packing unrelated work together.
12. **Hard to identify loop bodies** (floating nodes), making peeling/unrolling hard.
13. **Compiling is slow** (consequence of 6/7/8).
14. **SoN destroys any prior scheduling by construction**, which hurt carefully-scheduled WebAssembly.

Net result V8 reports: **compile time halved** vs SoN, the compiler is "a lot simpler and shorter", and debugging is "usually much easier".

Wikipedia states the decision was made in 2022; the primary blog says the effort started "almost 3 years" before Mar 2025. (Both consistent with "2022".)

### 1.5 Counterpoint: SoN research continues

SoN is not universally abandoned. GraalVM and HotSpot C2 still use it. Research continues, e.g.:

- *Lazy Sparse Conditional Constant Propagation in the Sea of Nodes* (CC 2024, DOI 10.1145/3679007.3685059) — a data-flow analysis specialized for SoN.
- Demange, Fernández de Retana, Pichardie, *Semantic reasoning about the sea of nodes* (CC 2018) — formal semantics.

Cranelift's mid-end also adopts a **hybrid**: CFG for effectful operations, SoN for pure operators (§4). The lesson is not "SoN is useless" but "pure-SoN for a dynamic language with pervasive effects is a bad trade; a CFG with a floating pure-expression layer captures much of the benefit."

---

## 2. Tilde Backend (TB) — RealNeGate

**Primary source:** *Tilde, my LLVM alternative* (`yasserarg.com/tb`), by Yasser (RealNeGate). Mirror repo/roadmap: `github.com/c3lang/tilde-backend` (a mirror; canonical is `RealNeGate/tilde-backend`, used by Cuik). TB is the backend of the **Cuik** C11 compiler.

### 2.1 Stated design and features

- **Sea of Nodes IR** ("opposed to LLVM or GCC's SSA CFG").
- **Simple type system.**
- **Fast compile times** as an explicit goal.
- **Thread-safe modules**: two functions can be generated/compiled concurrently.
- **CodeView debug info** ("windows debuggers will handle it just fine").
- **JIT and AOT**, plus "early work on directly outputting linked executables thus bypassing the need for a conventional linker."
- Motivation: LLVM is "far too slow at compiling and far too big to be fixed from the inside"; TB aims to fill a similar niche to early LLVM as a clean, decoupled library.

### 2.2 Optimizer and regalloc status (per author)

Optimizer "in progress", with expected passes "SSA construction, SCCP, folding, GVN, DCE, and code motion", plus "a decent **linear scan** allocator which will eventually be **replaced with graph coloring** for optimized builds."

### 2.3 Roadmap (mirror README, at access time)

- **Codegen:** starting with x64, moving to AArch64.
- **Optimizer:** "almost complete with all the -O1 level passes (mostly missing inlining)"; then -O2-level "the goal is to compete with LLVM".
- **Debug info:** "Codeview support and DWARF has not yet been started"; plans for a new debug format.
- **Output targets:** "basic ELF64, COFF64, some current work … for PE and Mach-O. We got exporting object files but wanna go further because **linkers ain't supposed to be separate programs**."

### 2.4 Compile-time claims

The TB page shows `cuik -g -O1` vs `clang -g -O0` spall traces, claiming TB is faster **with** its optimizer on. The author explicitly says: "It's not a fair test on purpose to show what my slowest looks like compared to their fastest." So the demo is illustrative, not a benchmark. **[uncertain: not independently verified; author describes it as deliberately one-sided]**

### 2.5 Odin integration status

Odin work on a Tilde backend officially started July 2023 (Odin newsletter 2023-07). Per the Odin forum thread *"Tilde backend got removed"* (26 Mar 2026): the backend "was put on pause because negate was busy with work and wasn't good enough yet"; a stated reason is not having to maintain two backends. **[uncertain: community forum, not an official commit message; verify against the Odin repo history before relying on it]**

**Takeaway for this project:** TB is the closest existing precedent (SoN + linear scan + direct object emission + AOT/JIT + designed for Odin). It is also a cautionary tale: a SoN-based custom backend stalled after years of lone-maintainer effort and was pulled back out. Its *feature* ambitions (fast, library, direct ELF, no external linker) are a good match; its *IR choice* (classic SoN) is the part V8 argued against.

---

## 3. QBE

**Primary sources:** `c9x.me/compile/`, `c9x.me/compile/doc/il.html`, `c9x.me/compile/doc/llvm.html`.

- Self-described goal: **"70% of the performance of industrial optimizing compilers in 10% of the code"**. The docs frame this as a guiding principle for selecting optimizations from the literature, **not a benchmarked result**. **[uncertain: widely repeated; a Reddit thread "is QBE 70% of LLVM?" notes it is a principle, and hands-on reports question the numbers]**
- **Size:** "less than 8 kloc" (QBE vs LLVM doc) — deliberately hobby-scale, C99, no dependencies, easy to hack, dumps IL/debug info after each pass. Author states it compiles in half a second on a Core 2 Duo.
- **Targets:** amd64 (Linux/OSX), arm64, riscv64.
- **IL character:** textual, typed but lightly; four base types (`w,l,s,d`) plus `b,h` extended; pointers are just `l`; **a full C ABI** including struct args/returns and variadics is implemented for you (a notable advantage over LLVM, where frontends often reimplement the ABI).
- **SSA/phi:** supports `phi` and SSA, but explicitly allows **non-SSA temporaries** and will fix them up, so a frontend can avoid SSA construction entirely (e.g. `%x =w add %x, 1`). It calls phi "NOT necessary".
- **Memory/stack:** `alloc4/8/16`; loads/stores for all widths; `blit` for small constant-size copies.
- **Output:** QBE produces **assembly text**; the normal flow is `qbe -o out.s file.ssa && cc out.s`. It relies on an external assembler **and** linker. There is an embeddable `libqbe` form, but "all-in-one, no external tools" is not its default mode.
- **Optimizations:** copy propagation on SSA in ~160 lines (per its own doc).

**Takeaway:** QBE is the best model for *minimal, hackable, correct, text-artifact* backend design, and for the position that a small fixed-size codebase is a feature. Its textual IL and per-pass dumps are excellent for debugging and golden testing. Its limitations for us: text IL adds parse/print cost and it does not solve direct ELF emission.

---

## 4. Cranelift: acyclic e-graph (aegraph) + ISLE

**Primary sources:** Chris Fallin, *The acyclic e-graph: Cranelift's mid-end optimizer* (9 Apr 2026, `cfallin.org/blog/2026/04/09/aegraph/`); *Cranelift's Instruction Selector DSL, ISLE* (20 Jan 2023, `cfallin.org/blog/2023/01/20/cranelift-isle/`); RFC `bytecodealliance/rfcs/accepted/cranelift-egraph.md`; regalloc2 write-up (`cfallin.org/blog/2022/06/09/cranelift-regalloc2/`).

### 4.1 sea-of-nodes-with-CFG

Cranelift's mid-end **keeps the CFG for side-effectful operations** (the "side-effect skeleton") and uses a **sea of nodes for pure operators only**. Rationale, per the author:

- It solves the **pass-ordering problem** (GVN vs redundant-load elimination requiring repeated passes to reach a fixpoint) with a single fine-grained fixpoint loop.
- Pure operators are canonicalized by hash-consing (GVN), then elaborated back into the CFG; DCE, LICM, and rematerialization fall out of translation.
- Fallin explicitly notes the V8 post as evidence that a *pure* SoN is hard for engineers, but argues the **sea-of-nodes aspect and the translation passes are more fundamental than the "equivalence class" part**.

Implementation notes that matter for a small compiler:

- **Aegraph = acyclic e-graph**, built in place in the existing SSA IR. An SSA value is an operator result, a block param, or a **union node** of two values. A trivial e-class (one e-node) is a no-op, so the lift to an e-graph is free until you use multi-representation.
- **Eager rewriting + append-only union nodes preserve acyclicity**, enabling a **single pass** instead of an equality-saturation fixpoint. This is the key trick that makes e-graphs production-viable.
- **Extraction is NP-hard** in general ("choose the cheapest expression per e-class").
- A **classical e-graph** was measured at **23% overhead with no rewrites** after tuning (initially >2×), replacing a pipeline that was itself only ~10% of compile time. This is why they avoided copying into a separate e-graph structure.

### 4.2 ISLE (instruction selection/lowering expressions)

- A **typed term-rewriting DSL** that compiles to Rust. ~**27k lines of DSL** now express both per-target lowering and mid-end rewrites.
- Key ideas: **external extractors/constructors** (patterns match via Rust functions, so no reified AST is needed); **strong types with sum types** (e.g. an `AMode` type that only allows legal addressing forms); **implicit conversions** (`Value→Reg` via `put_in_reg`, `Value→Inst` via `def_inst`) to keep rules natural.
- **Correctness tooling:** an **overlap checker** requires disjoint-priority rules for overlapping patterns and found **shadowed/unreachable rules**; there is ongoing work to lower rules to SMT for equivalence checking.
- Deterministic/verifiable: once a pattern matches there is no backtracking; the execution model is direct Rust function calls, so generated code is as fast as handwritten.

### 4.3 regalloc2 (for the RA discussion in §8)

- Ported from IonMonkey's **backtracking** allocator: compute **liveranges**, merge into **bundles**, assign locations, **split/evict** when needed, then resolve **parallel moves** (cycles via scratch register or stackslot).
- Emphasizes **cache locality**: contiguous inline structs instead of linked lists, bitpacked operands (32-bit), sort-based bulk move generation.
- Cranelift found **regalloc dominated compile time**; regalloc2 improved overall compiler speed ~20% and some runtime benches 10–20%.
- Important ISA-facing abstractions: **operand position (early/late)** and **reuse-input constraints** (needed for x86 two-operand `add rax, rbx`, fixed-register `mul`/`div`, `cl` shifts, and ABI-fixed call args).

**Takeaway:** Cranelift is the state of the art for "small-ish backend, strong correctness tooling, good compile speed." But the aegraph + ISLE stack is a large, mature investment; adopting it wholesale is not a from-scratch solo project.

---

## 5. LLVM: `-O0` vs FastISel/GlobalISel costs

**Primary sources:** LLVM GlobalISel docs (`llvm.org/docs/GlobalISel/index.html`); LLVM tutorial ch. 8 (compile to object code); GlobalISel PLDI/egraphs material; anecdotal measurement in jondgoodwin, *Compiler Performance and LLVM* (9 Mar 2019).

- LLVM has **two/three instruction selectors**: **SelectionDAG** (optimizing, builds a dedicated IR → compile-time cost), **FastISel** (fast, per basic block, prioritizes speed over optimization, "limiting support to common data types that fit within a single machine register", with fallback to SelectionDAG), and **GlobalISel** (successor to both, operates on the whole function, operates directly on MIR/GMIR).
- At `-O0`, LLVM aims for speed; FastISel is the fast path for several targets. GlobalISel's own docs state: "Currently, compile-time of the fast pipeline is within **1.5×** of FastISel. We're optimistic we can get to within 1.1/1.2×, but **beating FastISel will be challenging** given the multi-pass approach."
- Even a tiny program pays **fixed** backend overhead. In one measured example (single small program, 2019, Cone compiler) the LLVM backend was **99.3% of total compile time**, of which ~2.5 ms setup, ~3 ms IR verify, ~15 ms optimize, ~84 ms `gen obj`. Disabling codegen optimization **roughly halved** codegen time. **[uncertain: single program, old blog, not a controlled benchmark]**
- Practical implication: LLVM's floor is high and largely *fixed + per-function*, and even `-O0` is not "free". This is the core motivation for QBE/Cranelift/TB-style backends.

---

## 6. Tradeoff comparison

Ratings are qualitative and, except where sourced, **[my estimate]**. "Solo effort" = effort for one experienced systems programmer to reach a *correct, usable* x86-64 Linux backend.

| Dimension | Sea of Nodes (pure) | SoN-with-CFG hybrid (Cranelift-style) | CFG SSA (QBE / Turboshaft / LLVM) | E-graph / ISLE (Cranelift) | TB (SoN + LS) |
|---|---|---|---|---|---|
| **Compile speed** | Poor for effect-heavy code; V8: halved after leaving | Good (single fixpoint, in-place) | Good-excellent; QBE "half a second" build, Turboshaft fast | Good after tuning, but 23% e-graph overhead pre-rewrites | Goal is fast; claims unverified |
| **Memory** | High (nodes with input+use pointers, scattered; in-place mutation) | Moderate | Lowest (compact, block-local) | Moderate (union spines, scoped hashmap) | Not documented |
| **Correctness / testability** | Hard: effect/control chains, scheduling, deadness ([V8](#sources)) | Medium-hard, but translation passes are testable | **Best**: print IR per block, golden tests, block-local reasoning | Best-in-class *tooling* (overlap checker, SMT plans); high up-front cost | Hard (SoN) |
| **Optimization power** | High in theory for pure code; **limited in practice** when effects dominate | Most of SoN's benefit + CFG clarity | Lower ceiling than egraph, but 80/20 (QBE: 70% perf in 10% code) | Highest (equality saturation), but NP-hard extraction | Ambitious (-O2 goal) |
| **Solo effort** | Deceptively high (scheduler + effect chains) | High | **Lowest** (QBE <8 kloc; Simple ch.19–21) | Very high | Medium-high; stalled in practice |
| **Best for** | JITs with mostly-pure IR (C2, Graal) | Production with a team | A first correct backend | Long-lived optimizer teams | "LLVM alternative" ambition |

**Scheduling**, specifically: pure SoN requires a global scheduler (Click's GCM). It is not "free reordering" — it must place deduplicated pure nodes at the common dominator of their users and *re-duplicate* them where beneficial, which V8 calls out as a major complexity source. A CFG gives you scheduling for free (program order) and lets you do local scheduling later.

**Debugging**, specifically: SoN graphs are hard to read and pass visitation order is unintuitive (V8: "changed once every 20 visits", load-elim bailouts, 3–7× cache misses). CFG IRs print as the source roughly reads and support `-dump-ir`-per-pass workflows (QBE does this after **every** pass).

---

## 7. Recommendation for a correctness-first pipeline

The goal is a **from-scratch x86-64 Linux Odin compiler** that is **correct first**, then fast, then optimizing. The evidence above strongly favors a **CFG-based SSA IR** with a **small, printable, arena-allocated** design, and *deferring* SoN/e-graph machinery.

### 7.1 Minimal IR (start here)

Adopt a **CFG of basic blocks with block-local SSA and block parameters (or phi nodes)**:

- **One function = a list of basic blocks**; each block = a list of instructions + a terminator. Program order is explicit → scheduling is free, dumps read like the source, and each optimization is a local/global dataflow pass you can unit-test.
- **SSA with block parameters** (Cranelift style) or phis (QBE style). QBE's observation is valuable: because SSA construction is hard, allow **non-SSA temporaries and fix them up**, or initially keep values in stack slots (LLVM-style `alloca`) and promote later. This dramatically lowers front-end complexity for a correctness-first start.
- **Small typed opcode set**, machine-independent: int/float arithmetic, compares, branches, `phi`/block-param, `load`/`store` (with explicit size + signedness), `call`, `select`, casts, `alloc` (stack), `gep`/address arithmetic. Keep the type system simple (QBE's `w/l/s/d` + subword types is a proven minimal point).
- **Explicit effect ordering**: keep everything in program order inside blocks (no effect chain to maintain). This is exactly the thing V8 measured as a win.
- **Textual dump** of the IR after every pass (`--dump-ir`, `--dump-before/after=pass`), QBE-style. This is your primary debugging and golden-testing surface.
- **Arena allocation** for all IR nodes; intern names. (jondgoodwin's Cone data: ~35 bytes of memory per source byte with an arena.) Avoid per-node `malloc`/`free`.

**Do not** start with a pure SoN. If you later want SoN's pure-code floating, adopt Cranelift's lesson (§4.1): keep the **CFG for effectful ops** and float only **pure** operators through a **hash-consing/aegraph** middle-end, introduced as an *optional* pass that consumes and produces CFG IR. Union-node aegraphs make this a pay-as-you-go upgrade rather than a rewrite.

### 7.2 Build order (each step independently testable)

1. **IR + printer + interpreter.** Like `Simple` chapter 8: execute the IR directly. You can now run real programs and diff against a reference (the existing Odin/LLVM output, or a C reference) **before** writing any x86-64. This is the single highest-leverage correctness decision.
2. **Trivial lowering / fast-isel equivalent.** Direct, unoptimized instruction selection. Correct and slow is fine.
3. **Register allocation: linear scan** (Poletto & Sarkar, *Linear Scan Register Allocation*, TOPLAS 21(5), 1999, DOI 10.1145/330249.330250; Wimmer & Franz extended it for SSA). It is fast, simple, and global; TB chose it and Cranelift's predecessor regalloc.rs is a reasonable middle ground. Only later consider regalloc2-style backtracking or graph coloring (compute the **liveranges/bundles/parallel-move** model from the start — it is the reusable core).
   - **x86-64 specifics you must model immediately:** early/late operand positions; `reuse-input` constraints for two-operand `add r, r`; **fixed registers** for `mul`/`div` (`rax`,`rdx`), shifts (`cl`), and ABI call args; caller-saved clobbers on calls; 16 GPRs + 16 XMM; stack alignment (16 bytes) at calls. These are exactly the constraints regalloc2 abstracts (§4.3) — a linear scan can handle them with fixup moves.
4. **Direct object/binary emission.** Two viable paths; pick based on whether you need libc early:
   - **(a) Relocatable `.o` (ET_REL)**: sections (`.text`, `.data`, `.rodata`, `.bss`), a symbol table, and relocations; then link with the system linker/`clang`. *This is the pragmatic correctness-first choice*: you can call libc, and a wrong relocation is caught by existing tools. QBE's normal mode is even simpler (emit `.s`, let `cc` assemble).
   - **(b) Freestanding static executable (ET_EXEC)**: ELF header + program headers + `_start` + syscalls, **no external assembler/linker** — the `dotink` "August" write-up and `Simple` chapters 21–22 are concrete references for hand-emitting ELF. The cost is you get **no libc** until you implement a runtime or implement dynamic linking (PLT/GOT + `interp`). TB's stated long-term goal is (b) ("linkers ain't supposed to be separate programs"), but for correctness-first, (a) lets you defer that.
   - Recommendation: **implement (a) first** (or emit `.s` and shell out to `clang` for the very first milestone), then add (b) as a self-contained writer behind the same codegen, so you can compare outputs byte-for-byte. Do **not** depend on an external assembler for the long-term product if direct emission is a goal — but do use one temporarily to validate encoders.
5. **Debug info (DWARF).** Start minimal: `.debug_abbrev` + `.debug_info` (compile unit + subprograms + variables) and `.debug_line` (line-number program mapping addresses → file/line). Validate with `llvm-readelf --debug-dump=decodedline,info` and `llvm-dwarfdump`. Useful primers: Swatinem, *A deep dive into DWARF line programs*; OSDev *DWARF*; the DWARF standard (dwarfstd.org). Note TB's choice: **CodeView first** (simpler, Windows-only), DWARF "not yet started" — a warning that debug-info is a large, separable effort; treat it as an optional milestone after codegen correctness.

### 7.3 When to add optimizations (in order)

Add only after the pipeline is correct end-to-end and covered by differential tests:

1. **Local peepholes + constant folding** (per-block, to fixpoint). Cheap, high value.
2. **Copy propagation + dead code elimination** (QBE: ~160 LOC for copy prop).
3. **Sparse Conditional Constant Propagation (SCCP)** — folds branches, big win, moderate complexity.
4. **GVN / CSE** — canonicalization; the base for everything later.
5. **Inlining** (the biggest -O2 win; TB lists it as the main missing -O1 pass).
6. **LICM, strength reduction, redundant load elimination** (needs alias analysis).
7. **Optional**: a Cranelift-style **aegraph for pure ops** to unify GVN/CSE/LICM/DCE behind one rewrite fixpoint. This is the right *place* to invest if you later want more power — but it is a mid-end project, not a prerequisite.

Do **not** adopt a full e-graph/equality-saturation stack or an ISLE-style DSL for a solo correctness-first effort. The 27k-line DSL and 23%-overhead e-graph are justified in a multi-year team context, not v1. The *ideas* to borrow cheaply: typed pattern matching over a small selector, a rule-overlap check (even a simple assert that no two patterns can both match), and a **`--dump-ir` after every pass**.

### 7.4 Correctness/testability strategy

- **Differential testing**: same source through your backend and through LLVM (the existing Odin LLVM backend) and through your own IR interpreter; compare program output. Run this in CI on every commit.
- **Golden IR/assembly tests** with the per-pass dumps; QBE's "dump IL after each pass" is the model.
- **Fuzzing** of the encoder and of the IR→IR passes.
- **Assertions everywhere**: verifier after each pass (dominance, well-formed SSA, register-class/constraint legality post-RA).
- **Stage gates**: don't optimize until the unoptimized path passes the differential suite; don't add DWARF until codegen is stable.

### 7.5 What to borrow from each system

- **QBE**: the honest "70%/10%" scope, <8 kloc discipline, textual IL, non-SSA temporaries option, per-pass dumping, C ABI implementation.
- **`Simple` tutorial**: chapter-by-chapter incremental structure, IR interpreter, GCM scheduling (when/if you go SoN), graph-coloring RA, **hand-written ELF encoding** (ch. 21–22).
- **Cranelift**: sea-of-nodes-with-CFG hybrid (pure ops only), aegraph union nodes + eager rewriting for a *later* mid-end, regalloc2's liverange/bundle/fixup model, ISLE-style typed patterns + overlap checks.
- **TB/Tilde**: proof that the fast-library-direct-ELF ambition is coherent; cautionary evidence on SoN + solo maintenance.
- **V8/Turboshaft**: strong evidence to **start with CFG SSA** and keep effects in program order.

---

## Sources

- Cliff Click, *Combining Analyses, Combining Optimizations* (Rice PhD thesis, Feb 1995). https://repository.rice.edu/bitstreams/c5ea1ab7-e6c6-41e7-8e06-3cd5b80aeccd/download
- Cliff Click, *Global Code Motion / Global Value Numbering* (PLDI '95). https://dl.acm.org/doi/10.1145/207110.207154
- Click & Paleczny, *A Simple Graph-Based Intermediate Representation* (IR '95). https://dl.acm.org/doi/10.1145/202530.202534
- Wikipedia, *Sea of nodes*. https://en.wikipedia.org/wiki/Sea_of_nodes
- `SeaOfNodes/Simple` tutorial (25 chapters, x86-64/RISC-V/ARM64). https://github.com/SeaOfNodes/Simple
- Darius Mercadier, *Land ahoy: leaving the Sea of Nodes* (V8 blog, 25 Mar 2025). https://v8.dev/blog/leaving-the-sea-of-nodes
- Demange, Fernández de Retana, Pichardie, *Semantic reasoning about the sea of nodes* (CC 2018). https://inria.hal.science/hal-01723236/file/sea-of-nodes-hal.pdf
- *Lazy Sparse Conditional Constant Propagation in the Sea of Nodes* (CC 2024). https://dl.acm.org/doi/10.1145/3679007.3685059
- Yasser (RealNeGate), *Tilde, my LLVM alternative*. https://yasserarg.com/tb
- `c3lang/tilde-backend` (TB mirror + roadmap). https://github.com/c3lang/tilde-backend
- `RealNeGate/Cuik` (C11 compiler using TB). https://github.com/RealNeGate/Cuik
- Odin forum, *Tilde backend got removed* (26 Mar 2026). https://forum.odin-lang.org/t/tilde-backend-got-removed/1697
- Odin newsletter 2023-07 (Tilde work start). https://odin-lang.org/news/newsletter-2023-07/
- QBE home. https://c9x.me/compile/
- QBE IL reference. https://c9x.me/compile/doc/il.html
- QBE vs LLVM. https://c9x.me/compile/doc/llvm.html
- Chris Fallin, *The acyclic e-graph: Cranelift's mid-end optimizer* (9 Apr 2026). https://cfallin.org/blog/2026/04/09/aegraph/
- Chris Fallin, *Cranelift's Instruction Selector DSL, ISLE* (20 Jan 2023). https://cfallin.org/blog/2023/01/20/cranelift-isle/
- Cranelift e-graph RFC. https://github.com/bytecodealliance/rfcs/blob/main/accepted/cranelift-egraph.md
- Chris Fallin, *Cranelift, Part 4: A New Register Allocator* (regalloc2). https://cfallin.org/blog/2022/06/09/cranelift-regalloc2/
- LLVM GlobalISel documentation. https://llvm.org/docs/GlobalISel/index.html
- LLVM tutorial ch. 8 (compile to object code). https://llvm.org/docs/tutorial/MyFirstLanguageFrontend/LangImpl08.html
- jondgoodwin, *Compiler Performance and LLVM* (9 Mar 2019). https://pling.jondgoodwin.com/post/compiler-performance/
- Poletto & Sarkar, *Linear Scan Register Allocation* (TOPLAS 21(5), 1999). https://dl.acm.org/doi/10.1145/330249.330250
- Mössenböck, *Linear Scan RA in the Context of SSA Form*. https://bernsteinbear.com/assets/img/linear-scan-ra-context-ssa.pdf
- Linus Lee, *Assembler in Ink, Part I: processes, assembly, and ELF files*. https://dotink.co/posts/elf/
- ELF format overview (Linux `man elf`, `llvm-readelf`). https://man7.org/linux/man-pages/man5/elf.5.html
- Swatinem, *A deep dive into DWARF line programs*. https://swatinem.de/blog/dwarf-lines/
- OSDev wiki, *DWARF*. https://wiki.osdev.org/DWARF
- *The DWARF Debugging Information Format*. https://dwarfstd.org/
