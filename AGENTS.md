# AGENTS.md

Rules for every contributor and agent working in this repository. Also read `docs/01-architecture.md`.

## Do not reinvent the wheel

Before building anything, look for an existing reference: documentation, a specification, or an implementation that already solves the problem. Study it, understand its logic and organization, then adapt the ideas into simple, idiomatic Odin. Never translate a C or Rust implementation line by line.

- Reuse our Odin fork (`/home/su3h7am/Projects/Odin`) first. Copy and adapt `core`, `base`, `core:odin/{tokenizer,ast,parser}` and other existing Odin code rather than rewriting it. Adaptation is fine; blind duplication is not.
- Reference material lives in `/home/su3h7am/Projects/refs`: `Odin-upstream`, `alloc/llvm-project`, `go/src` (compiler, linker, ELF), `zig`, `musl`, `relibc`, `rfcs/linux` (kernel docs, man pages), and others. Check it before designing.
- The compiler must not change the language. The same Odin program must behave identically under this compiler and the official LLVM one: same syntax, same semantics. Only the implementation underneath changes.
- Record in the commit message or the relevant doc which references informed the work.

## No third-party dependencies

The compiler is written entirely in Odin and depends only on the Odin language and its packages. It never links libc, glibc, musl or any other external library. A pure-Odin program compiled by it needs none either.

- Talk to the kernel directly through syscalls (`core:sys/linux` first; add missing syscalls there in the same style). Linux is the kernel; we implement what we need on top of it.
- Threads, memory, files, time and the rest are built from syscalls and Odin code. No `foreign import` of C libraries in the compiler or its runtime.
- Process entry (`_start`), the runtime startup and the syscall ABI are ours.
- Support for `foreign import` of user C libraries (for example SQLite) comes later. A libc dependency pulled in by such a library belongs to that library, not to Odin code.

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
- Run Odin with `ODIN_ROOT=/home/su3h7am/Projects/Odin /home/su3h7am/Projects/Odin/odin ...`.
