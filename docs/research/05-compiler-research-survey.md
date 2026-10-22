# Compiler research survey for a pure-Odin backend

Research survey prepared 2026-10-17. The verdicts below are proposals for this repository, not claims that every cited technique is a fit. Effort estimates are relative to the current architecture in `docs/01-architecture.md`. Reported benchmarks belong to their authors and are not reproduced here.

## 1. Sea of Nodes: strengths, limits, and newer work

The 1995 Click and Paleczny work presents SoN as a unified graph where data and control dependencies constrain scheduling and optimization; Click's later C2 talks stress compact nodes and rewrite-based optimization. [paper](https://dl.acm.org/doi/10.1145/202530.202534) [C2 talk](https://assets.ctfassets.net/oxjq45e8ilak/12JQgkvXnnXcPoAGoxB6le/5481932e755600401d607e20345d81d4/100752_1543361625_Cliff_Click_The_Sea_of_Nodes_and_the_HotSpot_JIT.pdf)

C2 and Graal show that SoN can support mature optimizing compilers, but graph readability, global scheduling, and early inlining are real engineering costs; Graal's 2020 tutorial focuses on visualizing and understanding graph structure. [C2 talk](https://assets.ctfassets.net/oxjq45e8ilak/12JQgkvXnnXcPoAGoxB6le/5481932e755600401d607e20345d81d4/100752_1543361625_Cliff_Click_The_Sea_of_Nodes_and_the_HotSpot_JIT.pdf) [Graal graphs](https://chrisseaton.com/truffleruby/basic-graal-graphs/)

In 2025 V8 reported replacing much of TurboFan's SoN backend with Turboshaft, a CFG IR, citing difficult visitation order and state tracking, cache locality, and the cost of managing effects/control in dynamic JavaScript. Its measured results are V8-specific, not a general SoN verdict. [V8 rationale](https://v8.dev/blog/leaving-the-sea-of-nodes)

SoN remains active in new work: Graal's lazy SCCP (2024) propagates constants from known constants over graph edges and reports visiting 20.5% of nodes on its test workload. [Graal SCCP paper](https://conf.researchr.org/details/issta-ecoop-2024/mplr-2024/6/Lazy-Sparse-Conditional-Constant-Propagation-in-the-Sea-of-Nodes)

**Adopt:** keep current SoN IR; profile node visits and memory locality before designing passes (S). **Avoid:** wholesale conversion to CFG based on V8's JS experience (L). **Watch:** lazy analyses and results on statically typed languages; track graph churn and pass complexity (M). Sources: [Click paper](https://dl.acm.org/doi/10.1145/202530.202534), [V8 post](https://v8.dev/blog/leaving-the-sea-of-nodes), [Graal SCCP](https://conf.researchr.org/details/issta-ecoop-2024/mplr-2024/6/Lazy-Sparse-Conditional-Constant-Propagation-in-the-Sea-of-Nodes).

## 2. Compile speed with competitive generated code

Go documents a staged compiler and parallel compilation across functions and packages; its experience suggests preserve a clear boundary between shared semantic work and independent function codegen. [compiler phases](https://go.dev/src/cmd/compile/README) [parallel compilation](https://go.dev/doc/go1.9)

Zig's compiler has used indexed interned data and compact arrays; arena allocation suits phase-lifetime objects, while data-oriented layouts should follow measured cache or memory pressure rather than fashion. [Zig InternPool analysis](https://readoss.com/en/ziglang/semantic-analysis-and-the-internpool-heart-of-the-compiler) [data-oriented compiler design](https://tweedegolf.nl/en/blog/88/data-oriented-design/)

Jai's publicly described two-backend arrangement separates a fast development backend from an optimizing backend. QBE and TCC make a similar point from different ends: a small, direct backend can compile quickly, but QBE explicitly targets a quality/complexity tradeoff and TCC optimizes mainly at expression level. [Jai compiler overview](https://github.com/Ivo-Balbaert/The_Way_to_Jai/blob/main/book/04A_More_info_about_the_compiler.md) [QBE](https://c9x.me/compile/) [TCC docs](https://bellard.org/tcc/tcc-doc.html)

V's own dashboard and release discussion expose stage timings and parallel C compilation gains, but its C-backend timings and benchmark claims are not directly comparable to our native backend. Hare uses QBE as a deliberately small backend; QBE's release notes show performance gains came from profiling and retaining a selected set of passes. [V dashboard](https://fast.vlang.io/2024.html) [V parallel build](https://github.com/vlang/v/discussions/23206) [Hare toolchain](https://harelang.org/blog/2022-04-25-announcing-hare/) [QBE 1.3](https://c9x.me/compile/release/qbe-1.3.html)

Function-level concurrency is a plausible fit once module dependencies and shared pools are explicit. Go's compiler discussion also warns that per-worker caches raise baseline memory and that concurrency benefits can plateau. [Go concurrency discussion](https://github.com/golang/go/issues/48497)

**Adopt:** profile compile phases and peak memory, keep node/IR storage indexed and arena-backed, and benchmark representative workloads (S). **Avoid:** treating LOC/s claims or a minimal backend as evidence of competitive optimized output (S). **Watch:** parallel function codegen after deterministic ownership is clear (M-L). Sources: [Go phases](https://go.dev/src/cmd/compile/README), [QBE](https://c9x.me/compile/), [Go concurrency](https://github.com/golang/go/issues/48497).

## 3. New optimization and code generation ideas

Egg demonstrates equality saturation for rewrite composition, but saturation can consume unbounded time and memory; Cranelift's production aegraph instead uses immutable acyclic classes and eager rewrites to avoid a global saturation loop. [egg paper](https://arxiv.org/abs/2004.03082) [Cranelift aegraph](https://docs.rs/cranelift-egraph/latest/cranelift_egraph/) [Cranelift design talk](https://pldi23.sigplan.org/details/egraphs-2023-papers/2/-graphs-Acyclic-E-graphs-for-Efficient-Optimization-in-a-Production-Compiler)

Souper synthesizes bitvector optimizations and has produced useful rules, but the research tool can impose substantial compile-time overhead. Alive2 provides bounded translation validation for LLVM transformations and found bugs, while remaining bounded for loops. [Souper paper](https://arxiv.org/abs/1711.04422) [Alive2 paper](https://dl.acm.org/doi/10.1145/3453483.3454030)

Copy-and-patch uses precompiled machine-code stencils for baseline/JIT code; it is a possible development-tier experiment, not an obvious replacement for this AOT compiler's verified IR and direct encoder. [paper](https://dl.acm.org/doi/10.1145/3485513)

MLIR's layered dialect model preserves high-level semantics through progressive lowering, but its broad extensibility carries framework complexity. Our existing staged pipeline already provides useful layers without adopting an open-ended dialect system. [MLIR paper](https://arxiv.org/abs/2002.11054)

Profile-guided layout can improve instruction locality after ordinary optimization. Propeller reports production gains beyond PGO/ThinLTO, but needs instrumentation/profile collection and linker support. [Propeller paper](https://research.google/pubs/propeller-a-profile-guided-relinking-optimizer-for-warehouse-scale-applications/) Tiered compilation is well established in JITs, but here its useful analogue may be selectable fast and optimized AOT modes. [Copy-and-patch paper](https://dl.acm.org/doi/10.1145/3485513)

**Adopt:** add a small rewrite set with interpreter-based equivalence tests and keep optimization cost measurable (S-M). **Avoid:** full egg-style saturation and an MLIR-scale generic framework (L). **Watch:** translation validation for integer peepholes, copy-and-patch for a distinct fast tier, and PGO layout once profiling/linking are mature (M-L). Sources: [aegraph](https://docs.rs/cranelift-egraph/latest/cranelift_egraph/), [Alive2](https://dl.acm.org/doi/10.1145/3453483.3454030), [MLIR](https://arxiv.org/abs/2002.11054), [Propeller](https://research.google/pubs/propeller-a-profile-guided-relinking-optimizer-for-warehouse-scale-applications/).

## 4. Compiler correctness and engineering practice

Differential testing is a strong fit because the official compiler defines observable behavior. Csmith and YARPGen find bugs by generating defined programs and comparing compiler outputs; YARPGen's optimization-targeted generation found hundreds of bugs in C/C++ compilers. [Csmith paper](https://dl.acm.org/doi/10.1145/1993498.1993532) [YARPGen paper](https://dl.acm.org/doi/10.1145/3428264)

For Odin, a generator must encode Odin semantics and avoid undefined or unspecified behavior only where the language actually has those categories. Cross-check official compiler output, this compiler's interpreter, and optimized/unoptimized builds; fuzz lexing, parsing, and checking separately as well as end-to-end.

Reduction is part of the testing system, not cleanup. C-Reduce's research found domain-specific reduction substantially smaller than generic delta debugging; Shrinkray offers language-neutral reduction when a stable interestingness test exists. [C-Reduce paper](https://dl.acm.org/doi/10.1145/2254064.2254104) [Shrinkray](https://github.com/DRMacIver/shrinkray)

Build the compiler itself with memory/undefined-behavior instrumentation where practical, and run generated tests through those builds. Sanitizers can have blind spots under optimization, so distinguish sanitizer coverage from proof of correctness. [UBfuzz paper](https://doi.org/10.1145/3617232.3624874)

Deterministic output is already an architectural rule here. Repeated identical builds support reproducibility; bootstrap comparisons and diverse double compilation address trust in compiler binaries, a separate concern from semantic testing. [DDC overview](https://dwheeler.com/trusting-trust/)

Diagnostics research and rustc's contributor guide favor precise spans, concise messages, related labels, and separate actionable help. [diagnostics survey](https://doi.org/10.1145/3344429.3372508) [rustc diagnostic guide](https://rustc-dev-guide.rust-lang.org/diagnostics)

**Adopt:** differential generated programs, reduction scripts, sanitizer-built compiler runs, and stable IR/executable goldens (M). **Avoid:** treating agreement between two compilers as proof, especially if they share a backend or semantics assumptions (S). **Watch:** DDC/reproducible bootstrap and diagnostics usability checks as project maturity grows (M-L). Sources: [Csmith](https://dl.acm.org/doi/10.1145/1993498.1993532), [C-Reduce](https://dl.acm.org/doi/10.1145/2254064.2254104), [rustc diagnostics](https://rustc-dev-guide.rust-lang.org/diagnostics).

## 5. Ginger Bill's stated design priorities and backend implications

Bill describes Odin's priorities as simplicity, clarity, compilation speed, orthogonality, and high performance. His 2017 backend article says LLVM dominated compile time and proposes an SSA/custom backend as an alternative; later statements stress control and avoiding dependence on LLVM behavior. [FAQ](https://odin-lang.org/docs/faq/) [custom backend article](https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin) [2019 article](https://www.gingerbill.org/article/2019/05/13/a-reply-to-the-road-to-zig/)

He has also described LLVM optimization as a semantics issue: passes that assume C-like undefined behavior can be invalid for Odin, and later versions were used to enable a more complete set of passes with Odin-appropriate IR. So a new backend must optimize Odin's actual semantics, not imitate C/LLVM assumptions. [Odin forum response](https://forum.odin-lang.org/t/is-it-true-that-odin-cant-be-as-fast-as-zig-rust-because-all-llvm-optimizations-arent-possible/221)

Optimization levels distinguish development and release tradeoffs. Historical backend notes name `-o:none`, `-o:minimal`, `-o:size`, and `-o:speed`; these flag names are version-specific evidence, not a permanent contract. The 2023 newsletter says the frontend was already quick and LLVM consumed most compilation time. [dev release notes](https://github.com/odin-lang/Odin/releases/tag/dev-2021-05) [2023 newsletter](https://odin-lang.org/news/newsletter-2023-07/)

Bounds checks are normally enabled and can be disabled locally with `#no_bounds_check`; the compiler should preserve those policy boundaries and only remove enabled checks when it proves them redundant. [directives](https://odin-lang.org/docs/directives/)

The context system implicitly passes a context pointer for Odin-convention procedures; its stated purpose includes interception of allocation and logging. Odin also exposes allocator choice and uses temporary arena-like allocation. Backend ABI lowering therefore must model the context argument exactly, while compiler implementation can use arenas according to lifetimes. [FAQ](https://odin-lang.org/docs/faq/) [context article](https://www.gingerbill.org/article/2025/12/15/odins-most-misunderstood-feature/)

Bill's design writing emphasizes explicit, readable behavior rather than hidden work. His 2018 compiler Q&A says he considered compile-time execution too complex and preferred a very fast compiler with staged builds. [compiler Q&A](https://www.youtube.com/watch?v=5jmxyIfyyTk) [FAQ](https://odin-lang.org/docs/faq/)

**Adopt:** preserve Odin semantics, explicit check policy, deterministic compilation, and fast development feedback (S). **Avoid:** importing C-specific poison/alias assumptions or changing language behavior to simplify optimization (S). **Watch:** a fast native backend tier alongside an optimizing tier, with debug quality and compile-time resource use measured separately (M-L). Sources: [2017 backend article](https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin), [Odin FAQ](https://odin-lang.org/docs/faq/), [optimization semantics discussion](https://forum.odin-lang.org/t/is-it-true-that-odin-cant-be-as-fast-as-zig-rust-because-all-llvm-optimizations-arent-possible/221).

## Open questions for the owner

- Which benchmark suite should set the compile-time and runtime baselines, and what memory ceiling matters?
- Should the first optimization target compile latency, peak memory, runtime performance, or a development/release mode split?
- What exact observable behavior must differential tests compare, including panic timing, diagnostics, and output determinism?
- Is function-level parallel codegen worth the memory and synchronization cost for current workloads?
- Which integer and floating-point IR rewrites merit bounded translation validation first?
- Should profiles influence block layout before the built-in linker supports fine-grained section ordering?
- What diagnostic compatibility is required with the official compiler, versus matching only acceptance and runtime semantics?
- Which bootstrap assurance goal is in scope: deterministic rebuilds, cross-compiler comparison, or diverse double compilation?

## Source scope and caveats

The survey skimmed `docs/research/02-son-gap-analysis-front.md`, `03-son-gap-analysis-back.md`, and `04-son-external-references.md`; detailed gap inventories already in those files are intentionally not repeated. The sources above are public web references. Search results and public pages were consulted; claims about author-reported performance figures remain attributed and unverified independently. Discord material is not publicly searchable, so this survey makes no claims based on private Discord posts.
