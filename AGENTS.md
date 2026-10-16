# AGENTS.md

Rules for every contributor and agent working in this repository. Also read `docs/01-architecture.md`.

## Prior-art check before every task

The orchestrator puts this at the top of every task it delegates, and no agent writes code until it is done. We already lost time having an agent write an x86-64 encoder that `core:rexcode/isa/x86` provides.

1. Search our copy of `base/` and `core/` (and `vendor/` in the fork) for an existing Odin package that solves the problem.
2. Search the official repositories on GitHub (`odin-lang/Odin`, `odin-lang/examples`, `odin-lang/pkg.odin-lang.org`) for existing code, open and merged pull requests, and issues on the problem.
3. Search `/home/su3h7am/Projects/refs` for specifications and reference implementations in other languages.
4. Report what was found and what will be reused before writing anything. Write only what is missing.
5. Check the result against Ginger Bill's stated vision for Odin and its compiler (`docs/research/01-gingerbill-vision.md`): the simplest efficient solution, idiomatic Odin, nothing that changes the language.

## Do not reinvent the wheel

Before building anything, look for an existing reference: documentation, a specification, or an implementation that already solves the problem. Study it, understand its logic and organization, then adapt the ideas into simple, idiomatic Odin. Never translate a C or Rust implementation line by line.

- Reuse our Odin fork (`/home/su3h7am/Projects/Odin`) first. `base/` and `core/` are already copied here; adapt them in place. Also adapt `core:odin/{tokenizer,ast,parser}` and other existing Odin code rather than rewriting it. Adaptation is fine; blind duplication is not.
- Reference material lives in `/home/su3h7am/Projects/refs`: `Odin-upstream`, `alloc/llvm-project`, `go/src` (compiler, linker, ELF), `zig`, `musl`, `relibc`, `rfcs/linux` (kernel docs, man pages), and others. Check it before designing.
- The compiler must not change the language. The same Odin program must behave identically under this compiler and the official LLVM one: same syntax, same semantics. Only the implementation underneath changes.
- Record in the commit message or the relevant doc which references informed the work.

## Dependencies and platforms

The compiler is written entirely in Odin. We implement the language, not a subset of it: syntax, semantics, ABI and the standard library stay compatible with the official compiler, and every platform the official compiler supports stays supported.

- On Linux there is no first-party C library, so Linux code talks to the kernel through syscalls (`core:sys/linux` first; add missing syscalls there in the same style). Never depend on glibc, musl or any other third-party libc on Linux. Process entry (`_start`), runtime startup and the syscall ABI are ours.
- Windows, macOS and the BSDs ship first-party system libraries. Their code may use those libraries, including their libc, through `foreign import` as the official library does. `core:sys/posix` stays; it is the portable layer over those systems.
- The standard library (`base/`, `core/`) is copied into this repository from the Odin fork and adapted when needed. Keep every platform's code in it, including platforms we do not target yet. Only Linux x64 is built and tested for now; failures of other platforms' code are ignored until we enable them one at a time.
- `foreign import` of user C libraries (for example SQLite) is supported later. A libc pulled in by such a library belongs to that library, not to Odin code.

## Naming

Follow Odin's naming conventions and best practices. Use clear, descriptive, self-explanatory names. Avoid unnecessary abstractions and names that don't clearly describe what something is or does.

- Spell names out. Only well-established abbreviations are fine (`len`, `idx`, `ptr`, `src`, `dst`, `alloc`).
- Single-letter names are acceptable only in very small scopes, such as a loop index.
- A variable used in several places, or a procedure called from several places, is named for its purpose.

## Comments

Keep comments to an absolute minimum. Use them only as concise documentation for things the code cannot adequately explain on its own.

- Never restate what the code does.
- No block comments narrating the why, how and where.
- If a comment is needed to explain a name, rename instead.

## Tests

Keep the number of tests to the minimum necessary. Write only tests that provide meaningful validation and real value.

- Test the higher-level procedure rather than each helper it calls, unless a helper is reused elsewhere or fails in ways the caller test would not reveal.
- Do not add a test for every procedure, enum or struct.
- Before adding a test, ask what bug it would catch that no existing test would.

## Workflow

- Version control is Jujutsu (`jj`) only. Agents do not run `jj` or `git`; the orchestrator commits.
- Every task (build, check, test, format, anything else) runs through Mise: `mise run <task>`. Tasks are executable Bash scripts in `scripts/` with `#MISE` headers, never inline TOML tasks. `scripts/_lib.sh` holds shared helpers and is not executable. Config is `.mise/config.toml`, which names the bootstrap `odin` binary (`ODIN_BIN`, from the fork); the scripts set `ODIN_ROOT` to this repository so `base/` and `core/` come from here.
- Available now: `mise run check [package]`, `mise run test [package]`, `mise run fmt [--check]`. A new kind of task becomes a new script.
- Run code through these tasks, not by calling `odin` by hand. Run `mise run fmt` and `mise run check` before reporting work done.
