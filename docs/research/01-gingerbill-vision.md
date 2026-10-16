# Ginger Bill's Vision for a New / Alternative Odin Compiler Backend

Research report. Compiled 2026-10-16. All claims are sourced below. Where a statement
is not by Ginger Bill (Bill Hall) himself, it is explicitly attributed, because several
widely repeated "backend" claims come from community members or from Yasser Arguelles
Snape (NeGate), not from Ginger Bill.

> Transcription caveat: auto-generated YouTube transcripts (e.g. the 2018 `Compiler Demo
> [Q&A]`) contain errors. Garbled numbers/statements are flagged inline.

---

## Timeline

| Date | Event / statement | Source |
| --- | --- | --- |
| 2016‑07 | First Odin commit; compiler written in C++ (C style); LLVM is the backend (earlier it transpiled to C). | [FAQ](https://odin-lang.org/docs/faq/) |
| 2017‑01‑03 | Streams "custom compiler backend development". | [tweet](https://x.com/TheGingerBill/status/816386148037775360) |
| 2017‑03‑09 | Handmade Network post: "Working on a Custom Backend for Odin" — SSA + generic bytecode, alternative (not replacement) to LLVM. | [blog](https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin) |
| 2018‑12‑02 | Compiler Demo Q&A: custom backend is on the timeline; reasons = compile times + control. | [video](https://www.youtube.com/watch?v=5jmxyIfyyTk) |
| 2019‑05‑13 | "A Reply to The Road to Zig 1.0": criticises designing around LLVM; says Odin is working to replace it. | [article](https://www.gingerbill.org/article/2019/05/13/a-reply-to-the-road-to-zig/) |
| 2020 | Handmade Seattle panel "The Race to Replace C and C++" (with Andrew Kelley, Josh Huelsman). | [guide](https://handmade-seattle.com/guide-sub/c/2020/race-to-replace-c-and-cpp) |
| 2021‑03/04 | Replaces the *old* LLVM backend (`.ll` files + `llc`/`opt`) with the in‑process LLVM C API backend (issues #891, #914, discussion #916). This is "new backend" in the *old* sense — still LLVM. | [#891](https://github.com/odin-lang/Odin/issues/891), [#914](https://github.com/odin-lang/Odin/pull/914), [dev‑2021‑05](https://github.com/odin-lang/Odin/releases/tag/dev-2021-05) |
| 2022‑02‑18 | Tweet: regrets using LLVM as backend; wishes he had started with a custom backend. | [tweet](https://x.com/TheGingerBill/status/1494771927193427978) |
| 2022‑11‑25 | Tweet: "95% of my compiler development woes are solely due to LLVM". | [tweet](https://x.com/TheGingerBill/status/1596283549346279424) |
| 2023‑01‑06 | Tweet: "Write your own backend." | [tweet](https://x.com/TheGingerBill/status/1611363978910863365) |
| 2023‑07‑14 | First commit of Tilde Backend (TB) work in Odin (`new-cg` branch territory). | [commit mirror](https://git.cozyair.dev/ed/Odin/commit/7cd2d14b6410a17783020cea390f2be9534fa432) |
| 2023‑07 | July Newsletter: "Work has officially started on the new custom backend for Odin using Tilde." | [newsletter](https://odin-lang.org/news/newsletter-2023-07/) |
| 2023‑07‑17…20 | Twitch/YouTube streams "Odin Compiler Development ~ Tilde Backend". | [YouTube](https://www.youtube.com/watch?v=ii8kiBt3cVw) |
| 2023‑08‑15 | Tweets: "DO NOT USE LLVM!"; "We are working on alternative to LLVM … The Tilde Backend … eventually make it [LLVM] opt‑in". | [tweet 1](https://x.com/TheGingerBill/status/1691519060570189824), [tweet 2](https://x.com/TheGingerBill/status/1691524085140873216) |
| 2023‑11 | Handmade Seattle: Yasser presents Tilde (Sea of Nodes, lightweight). Ginger Bill does a fireside chat with Abner Coimbre. | [writeup](https://carlsverre.com/writing/handmade-seattle-2023/) |
| 2024‑11‑03 | Forum: "the real solution is to just not use LLVM … We are working on the new backend so that compile times will be a lot faster." | [forum](https://forum.odin-lang.org/t/what-features-of-odin-do-you-dislike/132) |
| 2024‑11‑06 | Forum thread: "Are there still efforts in progress to replace LLVM?" Community says Tilde/Cuik lives in `new-cg`. | [forum](https://forum.odin-lang.org/t/are-there-still-efforts-in-progress-to-replace-llvm/308) |
| 2024‑10‑25 | Tweet: the custom "C0" backend idea was abandoned, not because it was bad, but because Tilde/TB could hypothetically emit C0‑like C. | [tweet](https://x.com/TheGingerBill/status/1849755694179770606) |
| 2025‑07‑03 | Tweet: "when I get back to working on the new custom backend, it should be possible to bring … compile times by an order of magnitude at a minimum". | [tweet](https://x.com/TheGingerBill/status/1940754475859484954) |
| 2026‑02/03 | Forum + PR: **Tilde backend removed** (`bill/remove-tilde`, PR #6483), shipped in `dev‑2026‑04`. gingerBill: "Our plan is to just write out own backend instead. It means we have full control over everything." | [forum](https://forum.odin-lang.org/t/tilde-backend-got-removed/1697), [PR #6483](https://github.com/odin-lang/Odin/pull/6483) |
| 2026‑05/06 | `-bedrock` restricted Odin subset mode merged (kernels/embedded-style). | [PR #6654](https://github.com/odin-lang/Odin/pull/6654) |
| 2026 | `core:rexcode` merged: multi‑architecture instruction encoder/decoder/printer written in Odin (x86, arm32/64, riscv, mips, ppc, 6502/65816, rsp) + an `ir` layer (wasm/spirv/llvm). | [PR #6839](https://github.com/odin-lang/Odin/pull/6839), [pkg](https://pkg.odin-lang.org/core/rexcode/) |
| 2026‑07‑07 | "Odin 1.0 Announcement": release renamed **Odin 2027**; RC before Christmas 2026, release Jan 2027. Inline asm is on the roadmap. | [video](https://www.youtube.com/watch?v=dLPAqXi9In0) |
| 2026‑10‑07 | Tweets: LLVM "abuse relationship"; "I do plan to have an alternative, but not fully escape? I doubt it'll ever happen now." | [tweet](https://x.com/TheGingerBill/status/2107943138476355896) |
| 2026‑10‑16 | Tweets (the key thread): wants an alternative "designed to be faster (in terms of development builds) and use less memory", and would make it "Sea of Nodes based". | [tweet](https://x.com/TheGingerBill/status/2111093119798087815), [tweet](https://x.com/TheGingerBill/status/2111093318537077075) |

---

## Direct quotes (short, with URL)

### On wanting a new/alternative backend, faster iteration, lower resource use, Sea of Nodes

> "2 GB? Then you have to prevent LLVM then."
> — gingerBill, 2026‑10‑16, replying to a proposal that compilers be constrained to ≤2 GB RAM.
> https://x.com/TheGingerBill/status/2111091908273668281

> "LLVM has been the bane of my existence for over a decade now, and I recommend no one to use it unless they are forced to. If I had the time and resources, I'd work on an alternative that was actually designed to be faster (in terms of development builds) and use less memory."
> — gingerBill, 2026‑10‑16.
> https://x.com/TheGingerBill/status/2111093119798087815

> "I'd even just change the approach too to be Sea of Nodes based too rather than the approach LLVM currently uses."
> — gingerBill, 2026‑10‑16 (continuing the same thread).
> https://x.com/TheGingerBill/status/2111093318537077075

### On LLVM as the problem (compile time, stability, debug info)

> "The biggest problem is fundamentally how much extra the compile times LLVM adds when I do. It's not even a small amount."
> — gingerBill, 2026‑10‑07.
> https://x.com/TheGingerBill/status/2107742696282653175

> "I have been dealing with LLVM for over a decade. It is an abuse relationship because it's just so poorly designed and not even stable. Things regularly break each version. I do plan to have an alternative, but not fully escape? I doubt it'll ever happen now."
> — gingerBill, 2026‑10‑07.
> https://x.com/TheGingerBill/status/2107943138476355896

> "If I can get debug generation to be a lot faster, I'll do it. But LLVM is just that bad and I am not sure if I can improve it on its own yet. I might have to get around it manually if I can."
> — gingerBill, 2026‑10‑07.
> https://x.com/TheGingerBill/status/2107863209944535546

### On the Tilde plan and "don't use LLVM"

> "I agree with the piggyback off LLVM, and I regret my choices (which is why we are now moving towards the Tilde backend). This is why I tell anyone who wants to attempt to make a new language to stay away from LLVM as far as possible. DO NOT USE LLVM!"
> — gingerBill, 2023‑08‑15.
> https://x.com/TheGingerBill/status/1691519060570189824

> "We are working on alternative to LLVM for Odin's backend. The Tilde Backend … We will keep the LLVM backend, but eventually make it opt-in because there are times people will want LLVM (for some reason or other, unfortunately)."
> — gingerBill, 2023‑08‑15.
> https://x.com/TheGingerBill/status/1691524085140873216

> "If I was to go back in time, I'd just tell my past self to never touch LLVM and just write my own (optimizing) backend from scratch, as it would have taken less time to use/fix. I'd honestly say 95% of my compiler development woes are solely due to LLVM; it doesn't get better."
> — gingerBill, 2022‑11‑25.
> https://x.com/TheGingerBill/status/1596283549346279424

> "LLVM is a pain and I personally regret using it as a backend back when I started Odin. I wish I went with a custom backend from the beginning … I've been fighting it."
> — gingerBill, 2022‑02‑18.
> https://x.com/TheGingerBill/status/1494771927193427978

> "when I get back to working on the new custom backend, it should be possible to bring it down compile times by an order of magnitude at a minimum. LLVM is the vast majority of the compile time at the moment."
> — gingerBill, 2025‑07‑03.
> https://x.com/TheGingerBill/status/1940754475859484954

> "The custom C0 backend idea was abandoned, not because it was a bad idea, but rather Tilde/TB could be hypothetically used to generate C0-like C in the first place."
> — gingerBill, 2024‑10‑25.
> https://x.com/TheGingerBill/status/1849755694179770606

### On the 2026 decision to write their own backend

> "Our plan is to just write out own backend instead. It means we have full control over everything."
> — gingerBill, 2026‑03‑27 (forum reply to "Tilde backend got removed").
> https://forum.odin-lang.org/t/tilde-backend-got-removed/1697

### On motivations from the early custom-backend post (2017)

> "LLVM is slow – It takes up 85%+ of the total compilation time; even for non-optimized code."
> "LLVM is buggy – numerous bugs have been encountered with LLVM … many due to design flaws which can never be fixed".
> "LLVM is very big dependency".
> — Ginger Bill, 2017‑03‑09.
> https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin

### On the Tilde/LLVM relationship in the newsletter

> "Odin's compilation speed is actually quite quick, but LLVM slows down everything. Around ~90% of the compilation time is spent on LLVM." … "This will be an alternative to the current LLVM backend, and not a replacement to it."
> — July 2023 Newsletter.
> https://odin-lang.org/news/newsletter-2023-07/

### On design principles and backend-relevant reasoning

> "Odin was designed with the ideas of simplicity, clarity, speed of compilation, orthogonality of concepts, and for high performance. Feature X may be missing because it does not meet these basic ideas."
> — Odin FAQ.
> https://odin-lang.org/docs/faq/

> "Odin is not currently self hosted nor will it be until *after* version 1.0 … In general, self hosting before a stable language and compiler exists is masturbatory pleasure."
> — Odin FAQ ("Is the Odin compiler self hosted?").
> https://odin-lang.org/docs/faq/

> "The entire language specification should be possible to be memorized by a mere mortal."
> — Odin FAQ guiding principles.
> https://odin-lang.org/docs/faq/

> "While Odin does support LLVM as its main backend, LLVM's ability to generate machine code for a given platform is only part of the picture. The Odin compiler also needs to handle the platform's ABI … LLVM doesn't do that part automatically."
> — Odin FAQ ("If Odin uses LLVM, why doesn't it support every platform LLVM supports?"), also tweeted 2026‑04‑28.
> https://odin-lang.org/docs/faq/ , https://x.com/TheGingerBill/status/2049151275929874731

### Community / other people (NOT gingerBill) — labelled to avoid misattribution

> "the plan is to emit binaries (you know with actual machine code in the correct file format for each platform to just start running). The main reason is to not have to deal with llvm."
> — `ratchetfreak`, community member, 2026‑03‑31.
> https://forum.odin-lang.org/t/tilde-backend-got-removed/1697

> "Tilde/cuik is developed in the new-cg branch, there is lots of activity there (for a one man show). It's still planned as the way forward when it's stable enough."
> — `Laytan`, community/maintainer, 2024‑11‑06.
> https://forum.odin-lang.org/t/are-there-still-efforts-in-progress-to-replace-llvm/308

> "First up – @negate is building a compiler backend called Tilde! It's a Sea of Nodes based compiler that's lightweight and friendly to being embedded in other projects."
> — Carl (Handmade Seattle attendee), 2023‑11‑28.
> https://discuss.systems/@f0a/111490336606080589

---

## Motivations (why)

Ginger Bill's stated reasons for wanting to leave / de‑emphasise LLVM are long-running and consistent:

1. **Compile-time cost (the dominant reason).**
   - 2017 post: LLVM takes "85%+ of the total compilation time".
   - July 2023 newsletter: "~90% of the compilation time is spent on LLVM"; Tilde estimated to cut compile times "by an order of magnitude at a minimum".
   - 2024 forum post: "the real solution is to just not use LLVM … even 600KLOC compiles is about 2s for me [in the frontend]".
   - 2025 tweet: "bring it down compile times by an order of magnitude at a minimum."
   - 2026 tweets: LLVM "adds" a lot of compile time; a hypothetical alternative should be "faster (in terms of development builds)".
   - *Non-backend mitigation:* 2024–2026 he has also been optimising the LLVM path itself (multithreading the semantic checker; `-o:minimal` SROA/simplification passes; profiling the instruction selector; "LLVM Backend Performance Improvements to Reduce Compile Times" Parts 1–3).

2. **Memory / resource use.**
   - 2026‑10‑16: an alternative should "use less memory" (the thread is a reply about compilers being constrained to ≤2 GB RAM). This is a *newer* framing; earlier statements emphasise time and control more than RAM.

3. **Loss of control / restrictive design.**
   - 2017: "LLVM's design is restrictive – It was designed for C-like languages in mind so if your language deviates from this, it is annoying to handle".
   - 2018 Q&A: "the main reason for this is compile times and also control … LLVM has its ways of doing things and we can't always control that."
   - 2026 forum: "full control over everything."

4. **Bugs, instability, ABI/quirks, and version churn.**
   - 2017: numerous LLVM bugs; some are design flaws that "can never be fixed".
   - 2019 article: "a huge number of bugs and design flaws which cannot be avoided without removing LLVM itself".
   - 2026‑10‑07: "not even stable. Things regularly break each version"; LLVM is "crap with debug symbol generation" and forces disabling optimisations to get decent debug info.
   - 2026 FAQ: the compiler, not LLVM, must implement each platform ABI manually.

5. **Dependency weight / packaging.**
   - 2017: "LLVM is very big dependency".
   - 2019: "LLVM is a huge dependency which I would rather not have to deal with."
   - Installation/deployment discussions (Discussion #2708, 2023) are largely about the burden of shipping LLVM.

6. **Compile-time execution ambition (early).**
   - 2017: a bytecode from the backend could double as the execution target for compile-time execution, avoiding "two things that do a very similar thing".
   - Later (2018 Q&A) he leans against full compile-time execution as a language feature, preferring "the compiler should be extremely fast" and multi-pass builds instead.

7. **Concrete pain point: ABI/calling-convention bugs.**
   - 2017 thread documents a `{f32,f32}` argument being passed on the stack by LLVM instead of per the platform ABI — his motivating example.

---

## Stated goals

- **An alternative, not (initially) a replacement.** 2017 and July 2023 both frame it as an *alternative* backend that users can choose; LLVM kept.
- **Order-of-magnitude faster compile times**, especially for development/debug builds. (July 2023: "an order of magnitude at a minimum".)
- **Lower memory use** (2026‑10‑16 tweet).
- **Full control** over code generation and the whole pipeline (2026 forum: "full control over everything").
- **Sea of Nodes IR** is the IR approach he currently favours: "I'd even just change the approach too to be Sea of Nodes based too rather than the approach LLVM currently uses" (2026‑10‑16).
- **Emit native binaries directly** — machine code + object/file format per platform, bypassing a conventional C/LLVM step. (Community statement by `ratchetfreak`, 2026; consistent with the 2017 "generic byte code → specialize to machine architecture" plan and with the `-bedrock`/`rexcode` work. Ginger Bill has not, in the sources found, spelled out the emit path in as many words.)
- **Multiple backends eventually possible** (2017: "e.g. C, C++, LLVM, another language").
- **Tilde Backend (2023–2026, abandoned):** a Sea-of-Nodes, lightweight, embeddable backend by Yasser Arguelles Snape (NeGate), developed inside the Cuik C compiler, to make LLVM opt‑in.
- **Accuracy of debug info** as a first-class concern (2026‑10‑07 tweets: LLVM forces disabling passes to get correct debug symbols).
- **Language-level preconditions preserved:** Odin stays a 32/64‑bit, "modern systems" language; the backend must implement ABIs, not just target machine code.

---

## Stated non-goals

- **Not a full replacement of LLVM (at least in the Tilde era).** July 2023: "an alternative … and not a replacement to it." 2023‑08‑15: keep LLVM "but eventually make it opt-in".
- **Doubts about ever fully escaping LLVM.** 2026‑10‑07: "I do plan to have an alternative, but not fully escape? I doubt it'll ever happen now." The 2026‑10‑16 tweet is explicitly conditional: "*If* I had the time and resources".
- **Not self-hosting (the compiler) before Odin 1.0.** FAQ: compiler stays C++ until after 1.0; self-hosting is a post‑1.0 idea.
- **Not emitting C/C++ as the primary strategy.** The 2024 tweet says the custom "C0" backend idea was abandoned in favour of Tilde potentially generating C0‑like C; the 2026 removal and subsequent forum direction point to emitting binaries. (Whether a C-transpile path persists is unclear — see Open Questions.)
- **No 8-bit/16-bit targets.** FAQ: Odin will never support 8/16‑bit; it is a "language-level design decision". Backend target list stays amd64/arm64/wasm32(64p32).
- **No official package manager** (recurring principle; not a backend goal but part of the "minimal dependency" philosophy).
- **Compile-time execution as a language feature is treated with strong scepticism** (2018 Q&A; "If Odin Had Macros" 2025), despite the 2017 idea of a backend bytecode for CTE.
- **No official public roadmap.** FAQ: "There is no official roadmap … Public roadmaps are pretty much a form of marketing."

---

## Open questions

1. **Will the self‑written backend actually be built?** The strongest 2026 statement is conditional ("If I had the time and resources"). For the Tilde era it was concrete ("Our plan is to just write out own backend instead"), but 2026‑10‑07 hedges ("I doubt it'll ever happen now"). Status is genuinely uncertain.

2. **What exactly would the new backend's IR be?** He currently favours "Sea of Nodes based" (2026‑10‑16), which is the same family as Tilde/TB's IR. It is not stated whether this is a from-scratch design or a revival of Tilde, and V8's 2025 "leaving the Sea of Nodes" post is a counter-datapoint he has not (in these sources) responded to.

3. **What happens to Tilde/Cuik?** The Odin integration was removed (PR #6483, `dev‑2026‑04`, ~14.7k deletions). Cuik development has been quiet/slow (community observation); Tilde lives on independently at `c3lang/tilde-backend` (a C3 adoption) and `RealNeGate/Cuik`. Whether Odin could ever return to it is unstated.

4. **Emit path.** Forum consensus is "emit binaries", but Ginger Bill has not (in the found sources) stated whether the new backend would emit object files and rely on an external linker, or produce linked executables directly (which Tilde was experimenting with). The 2023 Discussion #2708 suggestion of compiling to a C subset is not confirmed as current.

5. **Implementation language.** The compiler is C++ today. Would a new backend be added in the existing C++ compiler, or written in Odin (self‑hosting, post‑1.0)? Not stated.

6. **Fate of LLVM.** Multiple statements say LLVM would remain available (opt‑in / fallback). The 2026 "not fully escape" statement reinforces this, but the exact long-term role (default vs. opt‑in vs. dropped) is unclear.

7. **Relationship of `core:rexcode` and `-bedrock` to the backend.** Both are strongly suggestive of a move toward self‑contained codegen (`rexcode` = instruction encoder/decoder for x86/arm/riscv/mips/ppc/etc.; `-bedrock` = restricted subset for kernels/embedded). Ginger Bill has not publicly tied them to the new backend in the sources found. (Uncertain — treat as signal, not statement.)

8. **Debug-info strategy.** He wants debug builds to be fast and accurate and says LLVM makes this hard/contradictory; how a custom backend would generate DWARF/CodeView (and CodeView support, which Tilde lacked) is unaddressed.

9. **Timeline.** No official roadmap; Odin "2027" targets RC ~Dec 2026 / release Jan 2027, with "stability, no grand new features" until then — which appears to push any custom backend work past 1.0. The 2026‑07‑07 announcement lists inline asm (roadmap) but does not mention a new backend.

10. **Migration/compatibility.** If a new backend lands, how existing LLVM-dependent behaviour (LTO, `-build-mode:llvm-ir/assembly`, `#must_tail`, debug info, `-o:minimal` pass tuning) is preserved is unspecified.

11. **"Odin compiler rewrite".** No explicit "full compiler rewrite" statement by Ginger Bill was found. The nearest concrete plan is the post‑1.0 self‑hosting idea and the "write our own backend". Treat "compiler rewrite" as unverified/unattributed.

12. **Discord.** Ginger Bill has historically discussed design on the Odin Discord, which is not searchable/publicly archived. Some nuance may live only there and could not be captured here.

---

## Sources

Primary (Ginger Bill / Odin project):
- Odin FAQ — https://odin-lang.org/docs/faq/
- "Working on a Custom Backend for Odin" (2017) — https://odin.handmade.network/blog/p/2210-working_on_a_custom_backend_for_odin
- "A Reply to The Road to Zig 1.0" (2019) — https://www.gingerbill.org/article/2019/05/13/a-reply-to-the-road-to-zig/
- July 2023 Newsletter — https://odin-lang.org/news/newsletter-2023-07/
- Odin GitHub: [#891](https://github.com/odin-lang/Odin/issues/891), [#914](https://github.com/odin-lang/Odin/pull/914), [#916](https://github.com/odin-lang/Odin/discussions/916), [Discussion #2708](https://github.com/odin-lang/Odin/discussions/2708), [PR #6483 Remove Tilde Backend](https://github.com/odin-lang/Odin/pull/6483), [PR #6654 `-bedrock`](https://github.com/odin-lang/Odin/pull/6654), [PR #6839 `core:rexcode`](https://github.com/odin-lang/Odin/pull/6839), [dev‑2021‑05](https://github.com/odin-lang/Odin/releases/tag/dev-2021-05), [dev‑2026‑04](https://github.com/odin-lang/Odin/releases)
- pkg docs: https://pkg.odin-lang.org/core/rexcode/ and https://pkg.odin-lang.org/core/rexcode/ir/
- Forum: ["Tilde backend got removed" (2026)](https://forum.odin-lang.org/t/tilde-backend-got-removed/1697), ["Are there still efforts in progress to replace LLVM?" (2024)](https://forum.odin-lang.org/t/are-there-still-efforts-in-progress-to-replace-llvm/308), ["What features of Odin do you dislike?" (2024)](https://forum.odin-lang.org/t/what-features-of-odin-do-you-dislike/132)
- "Odin 1.0 Announcement" (2026‑07‑07) — https://www.youtube.com/watch?v=dLPAqXi9In0
- Compiler Demo Q&A (2018) — https://www.youtube.com/watch?v=5jmxyIfyyTk
- X/Twitter (@TheGingerBill): 816386148037775360; 1494771927193427978; 1596283549346279424; 1611363978910863365; 1691519060570189824; 1691524085140873216; 1849755694179770606; 1940754475859484954; 2107742696282653175; 2107863209944535546; 2107943138476355896; 2111091908273668281; 2111093119798087815; 2111093318537077075

Secondary (other people):
- Yasser Arguelles Snape, "Tilde, my LLVM alternative" — https://yasserarg.com/tb
- `c3lang/tilde-backend` — https://github.com/c3lang/tilde-backend
- `RealNeGate/Cuik` — https://github.com/RealNeGate/Cuik
- Handmade Seattle 2023 writeup — https://carlsverre.com/writing/handmade-seattle-2023/
- Developer Voices podcast, "Is Odin 'programming done right'?" (2024) — https://www.youtube.com/watch?v=aKYdj0f1iQI
- Wookash Podcast (2024) — https://fountain.fm/episode/bfcF2GwLiBqeHZVbbwUS
- V8, "Land ahoy: leaving the Sea of Nodes" (2025) — https://v8.dev/blog/leaving-the-sea-of-nodes

> Note on X/Twitter provenance: X is not directly fetchable here; the tweets above were
> read via the Nitter-compatible mirror `nitter.cf/TheGingerBill` and canonicalised to
> `x.com/.../status/<id>` URLs. Text is quoted as shown by the mirror.
