# AGENTS.md

Rules for every contributor and agent working in this repository. Also read `docs/01-architecture.md`.

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
