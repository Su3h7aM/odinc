# 06 — PR #7850 (`-backend:fast`): IR, Analyses/Regalloc, Parallelism

Research report. Case study of the **closed** Odin PR #7850 *"Add `-backend:fast`, a
non-LLVM debug backend for x86-64 and arm64"* by `bbodi` (140 commits, +32,526/−111,
54 files; closed unmerged 2026-10-09). The only maintainer review is Ginger Bill:

> "No.\r\n\r\nThis is not maintainable." — gingerBill, `issues/7850/comments/6085338974`

**Scope of this report:** the IR (`src/xb_backend.hpp`), the analyses and register
allocator (`src/xb_analysis.cpp`), the deterministic parallel build
(`src/xb_shadow.cpp`), and the bail-out/fallback (in `src/xb_backend.cpp`). It is
*ideas only*: no code or design baggage is to be copied. Read-only review; every
claim is tied to `file:line` in the ref checkout.

**Checkout:** `/home/su3h7am/Projects/refs/odin-pr7850-fast-backend` (paths below are
relative to its `src/`). **What it is:** a *second* code generator bolted onto the
C++ compiler, selected by `-backend:fast`; it builds its own machine-level IR, does
its own DCE, its own register allocation, its own encoding and its own object
writing, and *falls back to LLVM per procedure* for anything it cannot yet do
(`xb_backend.cpp:1-5`).

**Verdict in one line:** several genuinely good, small ideas (whole-value scalar
promotion; caller/callee-saved choice by interval; rematerialisation; debug live
ranges = lexical scope; deterministic merge order) sitting inside a very large,
tightly-coupled, hard-to-reason-about machine that duplicates the LLVM backend's
semantics and hides failure in `setjmp`/`longjmp`. That combination is why the
answer was "not maintainable", not "wrong".

---

## 0. Prior-art check (required before any task)

Per `AGENTS.md` the first step is to ask what already exists in our copy of
`core/` and `src/`. Result for this scope (searched `/home/su3h7am/Projects/odin-compiler/core`):

| Topic | Prior art in our tree | Consequence |
|---|---|---|
| Index-handle / SSA IR vocabulary | **Yes.** `core/rexcode/ir/{module,refs,types,status,print}.odin`; `Module→Function→Block→Operation`, `Id`/`Ref_Space`/`Type_Ref`, `Operand` 16 bytes `#packed` (`module.odin:64-71`), `Operation.flags` `bit_field` (`module.odin:93-98`, `:104-110`). Design rationale in `core/rexcode/docs/ir_design.md` (the "three concessions", `:84-105`) and `cross_arch_design.md`. | Adapt the **vocabulary**, not a SoN. `ir_design.md:90` explicitly says `ir` owns structured `Module/Function/Block` "not a linear scan" — so it is *not* already a Sea of Nodes and has no effect/control chains. SoN parts are ours to write. |
| Index-based label bookkeeping | **Yes.** `core/rexcode/isa/labels.odin`: `Label_Definition :: distinct u32`, `LABEL_UNDEFINED` (`labels.odin:21-24`), forward refs (`:34`). | Concrete precedent for "ids are `distinct u32` in creation order", which our architecture already mandates (`docs/01-architecture.md:13,15`). |
| Deterministic parallel build / replay log | **No.** A case-insensitive search for "deterministic"/"replay"/"shadow" across `core/` finds nothing relevant (only unrelated graphics/`flags` hits). No thread-safe merge helper. | The *idea* to take is "merge in index order after parallel work". The generic log+replay **engine** is net-new and, I argue below, avoidable. |
| Thread pool / tasks | **Yes.** `core/thread/thread_pool.odin`: `Pool`, `pool_add_task`, `pool_pop_done`, mutex+futex `Sema` (`:30-56`, `:197-262`). | Reuse this for the driver's parallel build; do not write a task pool. |
| Register allocation / liveness / live intervals | **No.** `grep -ri` for `linear scan`/`liveness`/`regalloc` in `core/` only matches `rexcode` docs describing modules, not an allocator. | Regalloc is new work. Reuse only the *model* named in `docs/research/02-backend-ir-landscape.md:169-172,229-230` (liverange/bundle/parallel-move; early/late positions). |
| Per-phase arenas | **Yes.** `core/mem/virtual` `Arena` (`arena_init_growing` etc.), flagged for reuse in `docs/research/04-reuse-survey.md:491`. | Use it; do not port `xbArena`. |
| Sea of Nodes implementation | **No.** Confirmed in `docs/research/04-reuse-survey.md:28,558`. | Our SoN graph/verifier/scheduler are ours. |

So: the IR *vocabulary*, the thread pool, and the arena substrate already exist in
`core/`; the register allocator and the deterministic-merge logic do not — but most
of the PR's novelty in those two is avoidable given our design.

---

## 1. The IR — `src/xb_backend.hpp`

### 1.1 What it does (5–10 lines)

One enum `xbOp` (`xb_backend.hpp:65-164`) of **85 kinds** (confirmed by
`grep -c xbOp_`) from `xbOp_Nop` through arithmetic, casts, memory, calls, control
flow, atomics, and a long tail of *machine* ops (`Cpuid` `:153`, `Xgetbv` `:154`,
`Vec128` `:155`, `Valgrind` `:156`, `TlsAddr` `:158`, `Asm` `:161`, `Syscall`
`:150`, `MulHiU` `:152`, `FToHalf`/`HalfToF` `:159-160`). Every instruction is a
single **fat record** `xbInstr` (`:196-207`, ~40 bytes+): `op,type,aux,flags,dst,a,
b,c,mem,imm`, where the *same fields are overloaded per opcode* (`Branch` keeps its
second target in `c`, `:126`; `Call` keeps an index into `p->calls` in `imm`,
`:123`; `Select` reuses `c`, `:114`). Values are `xbValue` (`xb_gen.cpp:15-23`):
either a **scalar in a vreg** or a **place in memory addressed by `xbMem`**
(`xbValue_Mem`). Everything non-scalar (aggregates, slices, `any`, `#soa`) lives in
memory and is passed by address; addresses are described by `xbMem`
(`xb_backend.hpp:30-43`, kinds `Reg`/`Local`/`Sym`/`Incoming`, with a known
alignment that `xb_mem_offset` degrades as offsets are applied, `:53-63`). A
procedure is `xbProc` (`xb_gen.cpp:118-174`); the unit of work is `xbModule`
(`xb_backend.hpp:692-764`), which owns symbols, sections, relocations, debug tables,
generated-procedure caches, the lowering queue, the `handled`/`defined_procs`
entity sets, foreign libs, ObjC tables **and** the shadow state. Memory for IR comes
from a bump **arena** (`xbArena`, `:804-911`): `xb_arena_alloc_raw`/`alloc`
(4 MiB chunks, zeroed), `xb_arena_resize` grows the last allocation in place, and
mark/release (`xb_arena_mark`/`xb_arena_release`, `:874-887`) frees a procedure's
IR after lowering; it is `gb_thread_local` with a switchable current pointer
(`:813-818`).

### 1.2 Good ideas worth adapting

- **"Scalars in vregs, everything else in memory by address, with an explicit
  `origin` on a scalar loaded from memory"** (`xb_gen.cpp:20-23`). For a
  non-optimising debug backend this is a clean, fast rule: no SSA construction, no
  phi nodes (each vreg has exactly one definition, `xb_gen.cpp:111`), and aggregates
  never need to be decomposed. It is the same trade LLVM's `-O0` makes with
  `alloca`+load/store, and it is the right *speed* trade for a debug build.
- **A place/address abstraction with a small closed set of base kinds and a carried
  alignment** (`xbMem`, `:30-43`; `xb_mem_offset`, `:53-63`). "Where is this value
  and how is it aligned" as one value type, with alignment only ever *lowered* by an
  offset, is a good, checkable contract for a selector.
- **A tiny fixed scalar type set** (`xbType` `:11-21`: I8..I64, F32, F64, and a
  `V128` used *only* for ABI pieces, `:19`), with sizes in one table (`:23-27`).
  Keeping V128 out of the value model and only in ABI handling is a good boundary.
- **Explicit `init`/`reset`/`destroy` with reserved capacities**, with shadows
  starting small and the real module pre-reserving (`xb_shadow.cpp:6-43`). The
  intent — pay for capacity only where it is used — is sound.
- **Arena that keeps pages mapped across a reset and returns zeroed memory**
  (`xb_backend.hpp:797-849`). Zeroed-on-alloc removes a whole class of
  uninitialised-field bugs and is worth copying as a *policy* (not as code).

### 1.3 Poor design, and why it likely hurt maintainability

- **The fat, field-overloading `xbInstr` is the root maintenance cost.** There is no
  struct-of-arrays and no per-opcode payload type: `aux`, `a`,`b`,`c`, `imm`, `mem`
  mean different things for different `xbOp`s (`:65-164`), and the meaning is only
  documented in trailing comments. Every analysis must then re-derive the layout in
  a giant `switch` — `xb_for_each_vreg` alone is **145 lines** (`xb_analysis.cpp:3-145`)
  and `xb_op_is_pure` another 40 (`:149-188`). Adding one opcode means editing
  several such switches in lockstep; a missed case does not fail to compile — it
  silently mis-analyses, which for a register allocator means a miscompile. Our
  architecture explicitly rejects this (`docs/01-architecture.md:10,15`: SOA by
  `distinct u32`, tagged unions for payloads, `bit_set` flags).
- **Machine intrinsics are baked into the core opcode set** (`Cpuid`, `Xgetbv`,
  `Vec128`, `Valgrind`, `Prefetch`, `MulHiU`, `TlsAddr`, `FToHalf`, `Asm`, …,
  `:138-161`). That is why the enum is 85 wide and why the analyses must special-case
  each. A Sea of Nodes design should express these as nodes over an abstract
  intrinsic/effect model and let the x64 selector lower them, keeping the core
  opcode set small and target-independent.
- **`xbModule` is a ~60-field, ~15-array monolith** (`xb_backend.hpp:692-764`) that
  mixes object-file state, debug state, *and* parallel-build bookkeeping
  (`shadow_log`, `shadow_open`, `shadow_seen`, `lower_jobs`, `lower_busy`,
  `lower_sym_flags`, `lower_queued`, `lower_done`, `real`, `shadow_serial`, …,
  `:696-737`). The tell is that the same field list is repeated **three times** —
  `xb_module_init_tables` (`xb_shadow.cpp:6-43`), `xb_shadow_reset`
  (`:46-94`), `xb_shadow_destroy` (`:108-139`). Add one field and you must remember
  all three; forget the reset and a reused shadow carries stale state between
  families. That is a textbook maintainability hazard.
- **The IR is not actually a *machine-independent* IR.** It is close to an x64/arm64
  opcode list (shifts are documented as "raw x86 shifts, masked by the cpu", `:87`;
  `FToHalf`/`HalfToF` "arm64 only", `:159-160`). A Sea of Nodes IR should be a level
  above the ISA; here lowering is doing most of the work and the IR adds little.

### 1.4 How it translates to idiomatic Odin

- Represent the graph as **SOA arrays addressed by `distinct u32` handles**
  (`docs/01-architecture.md:15`), one small array per hot field, not one fat record.
  Opcode-specific payloads go in a **tagged union** (`union #no_niche`/`any`-style)
  or side tables indexed by handle, so the "which fields mean what" question is
  answered by the type, not by a comment. Reuse the `rexcode/ir` vocabulary
  (`Operand` 16 bytes `#packed`, `Result`, `Operation_Flags` `bit_field`,
  `core/rexcode/ir/module.odin:64,93,113`) rather than inventing a second one.
- Keep the **core node set small and target-independent**; push `Cpuid`/`Vec128`/
  `Asm`/`Prefetch`/TLS into an intrinsic node or an effectful "target op" that the
  selector recognises. Add a **verifier** in the same commit as the builder
  (`docs/01-architecture.md:9`), so a malformed node is caught by a check rather
  than by a later silent mis-analysis.
- Model effect and control as **explicit state edges** (`docs/01-architecture.md:9`),
  never "program order inside a block that analyses then have to reconstruct".
- Split the module: an `elf`/object-file struct (sections, relocs, symbols — the
  `driver`/`elf` packages already own this) vs a lowering/parallel context. Do not
  put the lowering queue and the section table in one struct.
- Reuse `core/mem/virtual` `Arena` and `core/container/*` instead of a bespoke
  bump allocator (`docs/research/04-reuse-survey.md:491,489`). If a per-procedure
  arena is needed, make it own its memory with an explicit `init`/`deinit`; keep
  "zeroed on alloc" as a policy, but do not implement a thread-local arena *switch*
  that IR lifetime depends on (see §3).

---

## 2. Analyses and register allocation — `src/xb_analysis.cpp`

### 2.1 What it does (overview)

Four things share the file: **dead-value removal** (`xb_cleanup_proc`, `:351-512`),
**dead-store removal** (same proc, `:449-511`), **which locals may live in
registers** (`xb_rank_promotable_locals`, `:240-345`), and a **linear-scan register
allocator over live intervals** (`xb_alloc_regs`, `:594-1191`, with slot reuse in
`xb_alloc_slots`, `:1195-1235`). The allocator builds per-vreg facts (`xbVregFacts`,
`:543-555`), computes global live intervals by a backward walk from first-read blocks
to kill blocks (`:884-946`), and scans them in program order (`:1138-1187`), giving
each interval a register or a spill slot.

### 2.2 Dead-value and dead-store removal (`:351-512`)

**Does:** counts vreg uses and tracks each vreg's defining instruction, then a
worklist (`work`/`drain`, `:436-447`) removes pure values (`xb_op_is_pure`,
`:149-188`) and non-volatile loads of locals/incoming that nothing reads (`:430-435`).
Then it removes stores to locals nothing reads (`:449-455`) and, per block, stores
that a later store overwrites before any read — using a 64-byte coverage bitmask per
local (`Cover`, `:459-510`). A debug variable's local is never removed
(`keep[]`, `:370-372`, honoured at `:394,480`).

**Good:** (a) Worklist DCE over a purity predicate is the right minimal form. (b) The
care that **loads may fault and divisions stay** (`:147-148`) is exactly the kind of
correctness distinction a fast backend gets wrong. (c) The **"a debugger may read
this local at any time, so keep its stores"** rule (`:349-350,371`) is a good,
debug-quality-first constraint that should be a first-class flag on a store, not a
side condition. (d) The block-local overwritten-store detection with a byte mask is a
cheap, local, correct-enough win.

**Poor:** the purity list (`xb_op_is_pure`) is a second hand-maintained switch that
must agree with the first (`xb_for_each_vreg`) and with the opcode set; a new opcode
that is pure but omitted here is simply never removed (silent perf loss), and one
that is impure but included is a miscompile. The 64-byte cover window, the
logical/shift `(1ull << size)` arithmetic, and the "reset coverage on any non-pure
op" rule (`:507-509`) are subtle and undocumented beyond one comment. It is ~160
lines doing what a small DCE pass over a real def/use structure would do more
clearly.

### 2.3 Which locals live in registers (`:190-345`)

**Does:** a local is *promotable* iff every access is a plain whole-value load or
store, same size, consistently int **or** consistently float, not volatile, not
address-taken, `over_align <= 16` (`:254`, `:331-333`); accesses are weighted
`loop_weight` inside a loop vs `other_weight` outside, and only locals above
`min_weight` are kept, ranked heaviest-first (`:335-344`). Loop membership is a
difference-array pass over back edges (`xb_blocks_in_loops`, `:212-238`).

**Good:** this is **mem2reg-lite** and it is the right scope: it promotes only locals
whose every access is provably a whole-value register move, which is safe without any
alias analysis, and it **ranks by weighted access count** so the allocator spends
registers on the hottest, not the first-seen. The loop-detection-by-back-edge with a
difference array is small and readable.

**Poor:** magic constants everywhere — `over_align <= 16`, weights `16/1/0`, and
`1ll << (3*min(depth,6))` (`:679`) i.e. 8^depth capped at 8^6. None is named or
justified. The caller passes `call_mem=true, by_ref_reg=true` (`:604`) and the
prologue re-uses the *same* ranking weights (`xb_alloc_regs` recomputes its own
`bweight`, `:655-680`) — so the "loop weights" live in two places with two different
formulas. Coupling the promotion decision to the allocator's cost model is fine, but
duplicating the cost model is not.

### 2.4 Linear-scan register allocation (`:518-1191`)

**Does:** for vregs used in one block it makes a def→last-use interval; for
cross-block vregs and promoted locals it makes **one global interval covering every
point liveness finds them live**, found by a backward pass from the block where the
item is first read to the blocks that kill it (`:884-946`). It has special cases:
**`remat`** — a frame-address `Lea` is recomputed at each use instead of living in a
register (`:704-707`, `:567`); **`is_const`** — an integer constant is materialised
at each use (`:700-703`, `:561`); **`via`** — a load coalesces with the register of
the local it loads, and a store's vreg is computed *in* the local's register when
nothing reads/writes in between (`:947-1005`); **`want`** — a vreg read only as a
call argument is placed directly in its argument register (`:1163-1182`). Selection:
an interval takes a **caller-saved** register when no clobbering (calling)
instruction overlaps it, a **callee-saved** one otherwise, and a *parameter* stays
in its arriving register when possible (`:1062-1137`). If no register is free, the
active interval with the lowest memory cost per position is evicted to its slot
(`:1081-1107`); an interval that loses lives in its slot for its whole life.

**Good ideas to adapt:**
- **Global intervals for cross-block values, block-local intervals otherwise**
  (`:518-525`) — the standard, correct shape of linear scan, and cheap.
- **Caller-saved unless a call overlaps the interval; callee-saved otherwise**
  (`:1066-1079`). This is the single highest-value heuristic for a debug build: it
  avoids a save/restore for every short-lived value that never crosses a call, and
  only pays for callee-saved registers when they actually help. Worth keeping.
- **Rematerialise instead of spill** for frame addresses (`remat`) and integer
  constants (`is_const`), and **coalesce through a promoted local's register**
  (`via`). Three cheap, high-yield, classic wins; all three should be first-class in
  a new allocator.
- **Spill by cost** = references × loop weight ÷ interval length (`:1084-1096`),
  rather than by interval length alone. Small change, real benefit.
- **Debug variable keeps its register for its whole lexical scope** (`:1007-1023`):
  a scope's `[smin,smax]` is merged into a live interval anchored around the scope,
  so a debugger shows the variable in a register across the scope. This is a
  *genuinely good* debug-info idea (the PR even reports it beats LLVM's CodeView
  `bit_set` output). Model "a debug name's live range is its lexical scope" as an
  explicit allocator constraint.
- **A parameter that arrives in a specific register keeps it** when no call forces a
  move (`:1069-1074`, `:1152-1153`): avoids a prologue move in the common case.

**Poor design, and why it hurt maintainability:**
- **~600 lines fused to one IR's struct layout and one target's callbacks**
  (`xb_alloc_regs` takes `clobbers`/`wants`/`pins` function objects, `:590-594`,
  `:722-724`, `:724`). It cannot be tested, changed, or reused independently: it
  reads `xbInstr`, `xbMem`, `xbCall`, `xbProc`, `xbDebugVar` directly throughout.
  The prior-art model (`docs/research/02-backend-ir-landscape.md:169-172,229-230`)
  says the reusable core is **liverange + operand-position (early/late) + reuse-input
  + parallel-move**, exactly the layer this allocator does *not* factor out.
- **Hand-rolled data structures**: `owner[64]` indexed by
  `(fp?XB_FREG:0)+r`, an `expire` array of intrusive linked-list heads, `active[]`
  with a `dead` flag (`:1046-1060`, `:1133-1135`). `XB_FREG = 32`, `XB_NOREG = -1`,
  and `XB_LOCAL_ITEM = 0x80000000` tag a single `u32` "item id" to mean *either* a
  vreg *or* a promoted local (`:528-533`, `:742-763`). That bit-tagging is the kind
  of cleverness that makes the allocator hard to modify; two explicitly-typed id
  spaces would be clearer.
- **Correctness depends on the two big switches being complete** (`xb_for_each_vreg`
  for def/use, and the target's `clobbers`/`wants`/`pins`). A wrong `clobbers` or a
  missing case in `xb_for_each_vreg` produces a live-range error, i.e. a
  wrong-register miscompile, with no verifier to catch it.
- **Magic thresholds**: `callee_weight` (`:539`, used `:1075`), the `> 256` /
  `256` adjacency limits when forming `via` (`:980`, `:992`). Unnamed and untuned in
  the open.

**How it translates to idiomatic Odin:**
- Make regalloc a **separate package** over an abstract interface: the IR produces
  **liveranges** and **operand constraints**; the allocator returns **locations and
  fixup moves**. Keep x64-64 specifics — early/late positions, reuse-input
  (`add r,r`), fixed `rax`/`rdx`/`cl`, caller-saved clobbers on calls, 16-byte stack
  alignment — as *data* in that interface (`docs/research/02:230`), not as targets
  callbacks reading a fat `xbInstr`.
- Use **two distinct handle types** (`distinct u32` for a vreg and for a promoted
  local) plus `bit_set`/named enums for pools; no `0x80000000` sentinel.
- Represent pools and clobbers with `bit_set[Register]` and name every cost constant.
- Keep the wins that are cheap and safe: caller-saved-first, remat, coalesce-through-
  local, assign-once-as-call-arg, spill-by-cost, debug-live-range = scope.
- Add a **post-allocation verifier** (dominance of def; no two live values in one
  register; alignment/`rsp` invariants) before emitting — the cheapest insurance for
  a hand-written allocator (`docs/research/02:256`).

### 2.5 Slots (`xb_alloc_slots`, `:1195-1235`)

Vregs with no register get 8-byte frame slots, and a slot is **reused** once its vreg
is dead within a block (`free_slots` stack, `:1200,1212-1231`). Good: block-local
slot reuse is a cheap memory win for a debug build. Poor: fixed 8-byte slots (so a
`V128`/aggregate vreg has no path here) and the "last use < current linear position"
freeing rule is another subtle correctness corner with no verifier.

---

## 3. Deterministic parallel build — `src/xb_shadow.cpp`

### 3.1 What it does (5–10 lines)

Building a procedure family mutates *shared* module tables (symbols, sections,
relocations, generated-type caches, `defined_procs`, `inline_statics`, foreign libs,
file ids). To build families on worker threads and still get a byte-identical object
at any thread count, each worker builds into a small **shadow module**
(`xb_shadow_make`, `:96-105`) that **logs every change** as an `xbShadowOp`
(`xb_backend.hpp:636-690`). The main thread then **replays** the log into the real
module in serial order (`xb_shadow_replay`, `:395-522`), renumbering the shadow's
symbols and file ids into the real module's (`xbRemap`, `:596-599`;
`xb_remap_proc`, `xb_backend.cpp:443-466`). The lowerer then runs off-thread and only
writes its own `xbLowerOut` (`xb_backend.cpp:586-605,468-488`); the driver appends
lowered procedures **in queue order** (`xb_lower_finish`, `:551-561`;
`xb_append_lowered`, `:491-542`), which is what makes the object thread-count
independent. Families are built in **windows** (256 at a time, `:215`) overlapped
with replay, backed by per-thread arena windows whose lifetime is tracked by
`last_job` vs `m->lower_done` (`xbWindowArenas`, `:146-187`). A shadow that a serial
build would have handled differently is flagged `shadow_serial` and built on the main
thread instead (`xb_shadow_compile`, `:526-541`; `xb_replay_possible`, `:335-349`).

### 3.2 Good ideas worth adapting

- **The determinism contract itself: byte-identical output at any thread count, and
  a CI check at 1 vs 10 threads** (PR body; `xb_backend.cpp:549-583`). This is the
  right, testable definition of "deterministic parallel build", and adopting the
  *test* — same input, N∈{1,10} threads, byte-compare — costs nothing and catches a
  whole class of bugs. Our architecture already demands it (`docs/01-architecture.md:46`).
- **Merge in index order, not completion order** (`xb_lower_finish` appends
  `m->lower_busy` in queue order, `:555-557`). This is the correct and only needed
  determinism ingredient, and it is exactly the rule `docs/research/04-reuse-survey.md:415-416`
  extracted from Go/rexcode.
- **Overlap build and replay with a small first window** (`:747-753`) is a sensible
  scheduling idea for a thread pool.
- **A shadow that would produce different results is re-run serially** rather than
  silently accepting a nondeterministic result (`:335-349`, `:526-541`) — the
  *attitude* (detect and fall back, do not gamble) is good.

### 3.3 Poor design, and why it likely hurt maintainability

- **The replay engine is a second implementation of the module's own semantics.**
  `xb_shadow_replay` (`:395-522`) is ~130 lines that must do, for every one of the
  ~20 `xbShadowOpKind`s (`xb_backend.hpp:636-657`), exactly what the real module's
  guarded operations do. `xb_shadow_*` wrappers exist alongside the real functions.
  Any change to how the module adds a symbol/section/reloc must be mirrored in the
  log op, the replay case, and the `shadow_seen` dedup — three places, silently
  inconsistent if one is missed.
- **This is the largest single win in the PR and the most complex piece.** The PR
  attributes the biggest speedup to it ("the replay engine ... costs nothing on one
  thread", PR body). So the maintainability-critical path is also the most intricate
  — the worst combination for a codebase Ginger Bill must own.
- **The subtle correctness argument is load-bearing and undocumented in code.**
  `xb_replay_possible` (`:335-349`) decides whether a skipped segment would have been
  done identically by a serial build; `xb_replay_skips` (`:315-329`) decides skips;
  `xb_shadow_seen` (`:927-939`) dedups with a packed `(kind<<56) ^ value` key and a
  `(depth<<40)|block` stamp. These rely on "the shadow did not have this change
  before the segment" reasoning that a future editor will not reconstruct.
- **Placeholder names leak into IR**: a shadow names an entity `"\x01%016llx"` of its
  **pointer address** (`xb_backend.cpp:86-107`). It is remapped before output, but it
  means the *identity* of an IR symbol during parallel build is an address, exactly
  the kind of pointer-order dependence `docs/01-architecture.md:13,46` forbids.
- **`lower_sym_flags` snapshots symbol flags at handover** (`xb_backend.cpp:565-583`,
  `xb_lower_sym_flags` header `:972-977`) because the main thread keeps adding
  symbols while workers lower. That is a symptom of sharing mutable module state
  across threads at all.
- **Arena lifetime is driven by `last_job`/`lower_done` bookkeeping across windows**
  (`xbWindowArenas`, `:146-187`; global `xb_windows_live`/`xb_windows_free`, `:151-152`).
  Correct IR ownership is now a global, cross-thread invariant that is hard to keep
  right and hard to test.

### 3.4 How it translates to idiomatic Odin

The key insight is that **most of the shadow machinery is needed only because the IR
builder writes shared module tables.** In our design we can remove that premise
instead of compensating for it:

- Build each function's IR into a **per-function arena** owned by that function, with
  **local** symbol references (interned ids or per-function placeholders). Do not
  touch the module's symbol table from a worker.
- **Resolve/merge deterministically on one thread**: iterate functions **by index**
  (creation order, `docs/01-architecture.md:13`) and assign real symbols, sections and
  file ids there. This is `xb_lower_finish`'s good idea, without the log.
- Then no generic replay engine, no `shadow_seen` dedup, no per-op replay switch, no
  `lower_sym_flags` snapshot, and no cross-thread arena lifetime logic are needed.
- Keep the **two invariants and their tests**: merge in index order; output byte-equal
  at 1 and N threads. Reuse `core/thread/thread_pool.odin` for the pool.
- Where cross-function shared work is unavoidable (generated per-type procedures,
  caches), make it **explicit and id-keyed**, computed in a deterministic pre-pass on
  one thread, rather than discovered and logged opportunistically by workers.

In short: adapt the *good* idea (deterministic index-order merge) and design away the
*reason* for the log, rather than porting the log.

---

## 4. Bail-out / fallback — `src/xb_backend.cpp`

### 4.1 What it does (5-10 lines)

The backend is *opt-in per procedure*: it runs before LLVM builds bodies, and any
procedure it compiles is only *declared* on the LLVM side (`:1-5`). A procedure that
uses an unsupported feature calls `XB_UNSUPPORTED(p, reason)`
(`xb_gen.cpp:209-217`), which records the reason and **`longjmp`s** out of the
builder to a `setjmp` installed in `xb_build_proc` (`xb_backend.cpp:276-283`); the
shadow's open segments are unwound (`xb_shadow_unwind`) and the procedure is left to
LLVM. The same `setjmp` pattern is repeated for generated equal/hash procedures
(`xb_gen_procs.cpp:162-172`, `:341-350`), statements (`xb_gen_stmt.cpp:4764-4766`),
globals (`xb_globals.cpp:252-254`, `:390-392`), ObjC (`xb_objc.cpp:184-186`) and type
info (`xb_type_info.cpp:454-456`). Fallback is logged with a source position
(`xb_log_fallback`, `:73-83`); `ODIN_XB_NO_FALLBACK=1` turns any fallback into a build
error for CI (`:807-812`); when nothing falls back, `m->complete` is true and LLVM
generates no code (`:787-791`). A battery of env switches (`ODIN_XB_STATS`, `_SERIAL`,
`_ONLY`, `_SKIP`, `_LIMIT`, `_VERBOSE`, `:669-674,704,808,833`) drives bisection.

### 4.2 Good ideas worth adapting

- **Per-function fallback with a recorded reason and position** (`:73-83`): the
  contract "either fully compile this procedure or leave it to the other backend,
  and tell the user where and why" is a sane way to grow a backend incrementally.
- **A CI gate that forbids silent fallback** (`ODIN_XB_NO_FALLBACK`,
  `:807-812`): treating "coverage lost to fallback" as a loud failure rather than a
  quiet degradation is exactly right for a project that intends to finish.
- **A coverage statistic by failure reason** (`xbStats.fail_reasons`, header
  `:607-615`; printed `:843-858`): a cheap, honest "what is not done yet" dashboard.
- **Snapshotted symbol flags at handover** (`:565-583`) is, in isolation, a correct
  way to make worker lowering independent of concurrent symbol mutation (it is a
  symptom of §3's shared state, but the technique of freezing a read-only snapshot
  for workers is good).
- The **`-backend:` switch** validated in `build_settings.cpp` and threaded through
  the driver is the right *shape* for an alternative backend, if we ever want one.

### 4.3 Poor design, and why it likely hurt maintainability

- **`setjmp`/`longjmp` as the control-flow operator for "unsupported".** It is used in
  **at least seven places** (grep: `xb_backend.cpp:277`, `xb_gen_procs.cpp:162,341`,
  `xb_gen_stmt.cpp:4764`, `xb_globals.cpp:252,390`, `xb_objc.cpp:184`,
  `xb_type_info.cpp:454`), and each site must correctly snapshot/unwind shadow depth
  and reset cache state (e.g. `xb_gen_cache_set(..., -2)` at `xb_gen_procs.cpp:166`).
  It silently skips destructors (the code even disables MSVC C4611 for this reason,
  `xb_backend.cpp:7-12`) and, in a language like Odin, has no place at all: Odin
  errors are values and the builder can return `(value, ok)` / propagate an error.
  `longjmp` past partially-committed state is precisely the kind of thing that turns
  a small bug into a hard-to-reproduce miscompile, and it is unreviewable in the
  ordinary way (control flow does not follow the call graph).
- **Fallback is all-or-nothing per procedure *family*, not per construct.** A single
  unsupported sub-expression discards the whole family (and every nested procedure in
  it), so coverage and the object layout depend on which unrelated feature happened to
  appear; the `_ONLY`/`_SKIP`/`_LIMIT` switches exist to make this diagnosable by
  hand — diagnostic surface that only exists because the failure model is coarse.
- **The "reason" is a bare `char const *` string** (`p->fail_reason`, `xb_gen.cpp:155`;
  `char const **reason` threaded through everything). No error codes, no structure,
  no i18n, no testability; the stats table keys on the string contents (`xb_stat_fail`,
  `:131-139`). Errors-as-values in Odin wants a typed error/`Maybe`.
- **Feature gates are scattered compile-time/runtime checks sprinkled through the
  builder** (`xb_backend.cpp:286-294`: naked, link section, instrumentation,
  sanitizers, internal linkage; `:147-151` candidate filter) rather than one
  declared capability description. There is no single place that lists "what this
  backend supports".
- **The driver is a monolith.** `xb_generate` (`:659-860`) is ~200 lines that does
  candidate collection, parallel windowing, fallback bookkeeping, startup/type-info/
  test-main generation, completeness computation, ObjC hand-over, lowering flush,
  object writing and stats printing in one function. Env switches for bisection are
  read inside it (`:669-674`). This is the "monolith" the review flagged: there is no
  seam to unit-test the driver's decisions.

### 4.4 How it translates to idiomatic Odin

- **No `setjmp`/`longjmp`.** The builder returns `(result, ok)` or an explicit
  error/`Maybe`; unsupported constructs set a typed failure with a source position and
  the *caller decides* what to abandon. Odin's `defer`/`or_return`/error-as-value
  idioms replace the bail-out machine entirely. If a whole-function abort is desired,
  model it as a small result type checked at the family boundary, not as a jump.
- Make capabilities **explicit**: one `Supported`/`Unsupported(reason)` result, or a
  declared set of supported constructs, checked *once* against the AST/IR, so
  `fail_reasons` is derived from a typed enum (deterministic order) rather than from
  string keys.
- Keep the **CI coverage gate** and the **reason-and-position diagnostics** — those
  are the good parts — but drive them from the typed result.
- Split the driver into `collect candidates` → `build (parallel)` → `lower/merge`
  → `write`, each a named procedure with a testable signature, per the pipeline the
  architecture already names (`elf`, `x64`, `driver`, `docs/01-architecture.md:21-32`).

---

## 5. Why "not maintainable": the cross-cutting reading

Ginger Bill's one-line verdict is not a judgement about any single algorithm — most
of the algorithms are reasonable, some are good. It is a judgement about the *shape*:

| Force | Evidence | Effect on maintainability |
|---|---|---|
| **Size** | +32,526 lines, 54 files, in one PR (PR metadata); `xb_gen_expr.cpp` 154 KB, `xb_gen_stmt.cpp` 185 KB, `xb_backend.hpp` 983 lines, `xb_gen.cpp`+`xb_analysis.cpp`+`xb_shadow.cpp` ~2.7k lines in scope alone. | Too much new surface for one person to own; review is infeasible (0 review comments, 1 maintainer comment). |
| **Duplicated `lb_*` semantics** | The builder is explicitly "a port of the `lb_*` builders, same semantics, same symbol names" (PR body); comments cite the originals throughout, e.g. the ABI is "a port of `lbAbiAmd64SysV`" (PR body), `lb_emit_conv` (`xb_gen.cpp:1672`), `lb_tls_realign` (`:1047`), `lb_debug_bitset` (`xb_dwarf.cpp:705`). | Every language/ABI/debug change must now be made **twice, identically**, in two languages. This is the single largest maintainability cost and exactly what "we implement the language once" forbids. |
| **`setjmp`/`longjmp`** | ≥7 sites (§4.3). | Control flow invisible in the call graph; skipped destructors; partial state; unreviewable. No place in an Odin codebase. |
| **Flags** | `xbInstr.flags` = one `u8` with one bit (`xb_backend.hpp:200,209-211`) while op-specific meaning lives in comments; **and** a scatter of env switches `ODIN_XB_{STATS,SERIAL,ONLY,SKIP,LIMIT,VERBOSE,NO_FALLBACK}` (`xb_backend.cpp:669-674,704,808,833`). | The one-bit `flags` field is where correctness-critical op properties should live (pure/volatile/faulting/can-float) and are instead re-derived by switches; the env switches are a hand-built diagnostic surface standing in for a proper capability/coverage model. |
| **Monolith** | `xbModule` ~60 fields with init/reset/destroy triplicated (`xb_shadow.cpp:6-139`); `xb_generate` ~200 lines (`xb_backend.cpp:659-860`); two 145/40-line opcode switches (`xb_analysis.cpp:3-145,149-188`). | Changes ripple; a new field must be added in three places; a new opcode in several switches with silent failure modes. |
| **Two backends, one language** | The PR keeps LLVM and adds `-backend:fast` that must link against LLVM's objects (`xb_backend.cpp:1-6`) and stay ABI-identical. | Doubles the surface that must agree, forever; the fallback seam makes it impossible to delete either. |

The maintainability conclusion: **the problem is not that the ideas are bad; it is
that they are delivered as a parallel, duplicated implementation of the parts of the
compiler we already have (semantics/symbols/ABI), with control flow hidden in
`longjmp` and shared state reconciled by a log-and-replay engine.** A from-scratch
pure-Odin compiler has the freedom to avoid the premise that created the log
(shared mutable module state during parallel build) and to make failure a value; both
of those remove the two most complex pieces while keeping the good ideas.

---

## 6. Take / leave, one line each

| Take (idea) | Leave (baggage) |
|---|---|
| Scalars in vregs, aggregates in memory by address; one definition per vreg | The 85-kind, field-overloading fat `xbInstr` with no SOA |
| A place/address value with a closed base-kind set and carried alignment | Machine intrinsics (`Cpuid`/`Vec128`/`Asm`/…) in the *core* opcode set |
| Tiny fixed scalar type set; `V128` only for ABI | A ~60-field `xbModule` with init/reset/destroy triplicated |
| Worklist DCE with a purity predicate; keep faulting loads/divs | A second hand-maintained purity switch beside the def/use switch |
| "Debugger may read this local" ⇒ keep its stores | A 64-byte ad-hoc store-coverage window |
| Promote only provably-plain whole-value locals, ranked by weighted access | Unnamed magic weights/thresholds (`16/1`, `8^depth`, `>256`) |
| Linear scan: global intervals for cross-block values, local otherwise | A 600-line allocator fused to one IR's struct layout and target callbacks |
| Caller-saved unless a call overlaps; callee-saved otherwise | `0x80000000`-tagged "item id" conflating vregs and locals |
| Remat frame addresses/constants; coalesce through a promoted local; place once-used call args in the arg register | `owner[64]` + intrusive `expire` list + `dead` flags |
| Debug name's live range = its lexical scope | Debug-scope merging wedged into the allocator with no verifier |
| Deterministic merge in index order; byte-identical at N threads (with the test) | The generic shadow log + `xbShadowOp` replay engine and `shadow_seen` dedup |
| Per-function fallback with reason + source position; CI gate against silent fallback | `setjmp`/`longjmp` bail-out, bare `char const *` reasons, one monolithic driver |
| Reuse `core/thread/thread_pool.odin`, `core/mem/virtual` `Arena`, `core/rexcode/ir` vocabulary | Reimplementing arenas, task pools and an IR vocabulary in a second dialect |

---

## 7. Sources

- PR #7850, `odin-lang/Odin`: <https://github.com/odin-lang/Odin/pull/7850>
  (metadata via `api.github.com/repos/odin-lang/Odin/pulls/7850`; 140 commits,
  +32,526/−111, 54 files, state `closed`, `merged:false`).
- Maintainer comment: `api.github.com/repos/odin-lang/Odin/issues/7850/comments`
  (`6085338974`, gingerBill, 2026-10-09: "No. This is not maintainable.").
- PR body (pipeline, fallback, parallelism, tests, switches, benchmarks) as returned
  by `api.github.com/repos/odin-lang/Odin/pulls/7850`.
- Source checkout: `/home/su3h7am/Projects/refs/odin-pr7850-fast-backend` —
  `src/xb_backend.hpp`, `src/xb_backend.cpp`, `src/xb_analysis.cpp`,
  `src/xb_shadow.cpp`, `src/xb_gen.cpp`, `src/xb_gen_procs.cpp`.
- Our tree: `docs/01-architecture.md`, `AGENTS.md`,
  `docs/research/01-gingerbill-vision.md`, `docs/research/02-backend-ir-landscape.md`,
  `docs/research/04-reuse-survey.md`.
- Prior art in `core/`: `core/rexcode/ir/{module,refs,types,status,print}.odin`,
  `core/rexcode/docs/ir_design.md`, `core/rexcode/isa/labels.odin`,
  `core/thread/thread_pool.odin`, `core/mem/virtual`, `core/container/*`, `core/sync`.
