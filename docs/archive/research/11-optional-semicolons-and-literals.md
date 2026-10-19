# Optional semicolons and the `1e1f` literal

Scope: how our parser should treat `invalid :: 1e1f` and optional semicolons, and what Ginger Bill (GB) intended for `core:odin/parser` and for a compiler's parser. Sources are the local fork `/home/su3h7am/Projects/Odin` (read with `git log` and `git show` only), two probe programs in `/tmp` (outside the repository), GitHub issues and PRs, and gingerbill.org and odin-lang.org pages.

Method notes:

- The GitHub REST API quota ran out partway through (60 requests per hour). Later lookups used the github.com pages.
- Probes used the fork's `odin` binary with `ODIN_ROOT=/home/su3h7am/Projects/Odin`. Without that variable the build failed with `Runtime procedure not found: native_memmove`.
- Skills (writing and prose checks) were not loaded for this document.

## Verdict

Our parser should reject `invalid :: 1e1f`. The official compiler rejects it, and the grammar in `odin.ebnf` also rejects it, though through a missing separator rather than a literal error. Our error should come from the literal token, with the compiler's message "Invalid integer literal".

Our parser should not copy the `Optional_Semicolons` mode of `core:odin/parser`. That mode is tooling leniency. It accepts same-line statements such as `a :: 1 b :: 2`, which the compiler rejects. The compiler's rule is generic: a statement ends at `;`, at a newline, before `}` or `)` on the same line, or at EOF. Anything else on the same line is an error. The compiler implements this in `expect_semicolon` with no per-node table.

## 1. Origin of `Optional_Semicolons` and `is_semicolon_optional_for_node`

Commit history in the fork (`git log` in `/home/su3h7am/Projects/Odin`):

| Date | Commit | Author | What it did |
|---|---|---|---|
| 2020-11-01 | `54fbdabc3` | gingerBill | Experimental `-insert-semicolon` in the C++ tokenizer and parser |
| 2020-12-06 | `ca4657fd3`, merged as `1eb1bffd8` (PR #799 "parser-experiments") | gingerBill | Adds `optional_semicolons: bool` and `is_semicolon_optional_for_node` to `core:odin/parser`, and semicolon insertion to `core:odin/tokenizer` |
| 2021-05-16 | `9ccdc40f6` | gingerBill | Changes the bool into `Flags`, with `.Optional_Semicolons` |
| 2021-08-31 | `1fff96e08` | gingerBill | "Make `-insert-semicolon` the default now" (compiler side of PR #1112) |
| 2021-09-06 | PR #1112 merged | gingerBill | Language change: semicolons become optional as statement terminators |
| 2021-09-20 | `50ee65ea9` (PR #1182, closes #1152) | Daniel Gavin | `default_parser` defaults to `Flags{.Optional_Semicolons}` |

Stated reasons, as far as the sources say:

- PR #799 has no description. Its merge commit message gives only the subject "Add experimental `-insert-semicolon` functionality to tokenizer and parser". The `Optional_Semicolons` flag commit (`9ccdc40f6`) has no message body. No reason is recorded for either.
- The default change came from issue #1152. After the language change, `examples/demo/demo.odin` gave "syntax error count: 1061" in `core:odin/parser`. PR #1182 closed it.

What `is_semicolon_optional_for_node` encodes: my inference is that it follows the pre-2021 compiler rules, since the 2021 article describes the old rules as the ones it replaced (https://odin-lang.org/news/optional-semicolons/). I did not diff the function against those rules line by line.

Intent, from the evidence:

- The package header says "The `Odin` file parser to be used in tooling" (`core/odin/parser/parser.odin:1`). The tokenizer and `core/odin/doc.odin` headers say similar things.
- The only motivating report for making the flag the default was a tooling use case (#1152).
- GB's commit `3da173087` (2026-10-09), subject "drop the reserved package name errors and make them opt-in for external tooling", removes reserved-package-name errors from `core/odin/parser/parser.odin` (around lines 189–196). The diff only removes them. The commit adds no opt-in flag, although the subject mentions opt-in.
- PR #2565 ("Added Flag.Allow_Reserved_Package_Name") was closed by GB without merge on 2023-06-26. GB's review said the file "isn't meant to be parsed whatsoever in general. It's purely for documentation and will contains syntax errors."

So the flag is for tooling, and the default is a tooling choice. Section 3 covers the parity rule that still applies: the core parser must not reject valid code.

Inside the flag, `is_semicolon_optional_for_node` returns true for every node (`core/odin/parser/parser.odin`, around line 561). The compiler has no such per-node table. Its only rule is `expect_semicolon` in `src/parser.cpp` lines 2024–2059, quoted in section 5.

## 2. `test_issue_integer_literal_exponent`: issue, fix PR and GB's words

- The test was added by commit `374024fc7`, "Parse integer literals without allocating per digit and reject non digits in their exponent" (2026-09-30, author Louis Novy). It was merged as PR #7686 (https://github.com/odin-lang/Odin/pull/7686), merged by Kelimion. Commit `edaaa27f8` (2026-10-09) later moved the test into its own directory: `tests/issues/test_issue_integer_literal_exponent/test_issue_integer_literal_exponent.odin`.
- The test contains `invalid :: 1e1f // Error`, with the comment "used to be accepted as 10". A grep for "Error:" in `run.sh` and `run.bat` counts one expected error.
- The PR body says: "1e1f was previously accepted as 10: big_int_exp_u64 reset *success ..." The rest of the body is not quoted here.
- No linked issue. A search of odin-lang/Odin for `1e1f` returns only #7686.
- Ginger Bill did not comment on #7686. The only PR comment is from Kelimion: "What an awesome little PR."
- The fix is in the compiler's integer-literal conversion. The PR did not change `core:odin/tokenizer`, which is why the core parser still splits `1e1f` (section 4).

## 3. What GB has said about parity, semicolons and tooling

Parity with the compiler: I found no statement by GB that `core:odin/parser` must match the compiler exactly. Unknown.

- PR #2649, "Match C++ parser behavior in allowing newlines before a closing brace" (opened by hchac), was merged by GB on 2023-08-07 as commit `488a38a`. The core parser had rejected valid code with "expected a comma, got a semicolon". The goal was valid code the compiler accepts.
- Issue #3715 (labels on `#reverse for in` and `#partial switch`): GB commented "Fixed in 1945218" on 2024-06-10. The reporter's point was that only the compiler had been fixed, not the core package. GB's commit `1945218f6` changed `core/odin/parser/parser.odin` and `src/parser.cpp`.

Semicolons, in GB's words:

- Issue #275 (2018-10-17), a comment by gingerBill: the rules are there "to make things _feel_ right".
- "A Reply to _Let's stop copying C_" (2020-01-25): for Odin, "it requires semicolons" (https://www.gingerbill.org/article/2020/01/25/a-reply-to-lets-stop-copying-c/).
- The 2021 article on optional semicolons (https://odin-lang.org/news/optional-semicolons/) and PR #1112 (https://github.com/odin-lang/Odin/pull/1112). The article says:
  - Semicolons "are still required" as statement separators.
  - "Having multiple statements per line, e.g. `foo(); baz(); bar()`" still needs them.
  - Optional semicolons "Aid with tooling such as code generation".
  - Tooling such as `odin strip-semicolon` and the upcoming `odin fmt` is cited as mitigation.
- The 2026 article "Choosing a Language Based on its Syntax?" (2026-02-19) gives two reasons for optional semicolons: "To make the grammar consistent, coherent, and simpler" and "To honestly shut up these kinds of bizarre people" (https://www.gingerbill.org/article/2026/02/19/choosing-a-language-based-on-syntax/).
- `odin.ebnf` lines 59–68 (https://odin-lang.org/spec/grammar/) describe automatic insertion: a newline acts as `;` after the listed tokens, and `;` is ignored inside `()`, `[]` and `{}`. `EXPONENT` (line 32) uses `DIGIT` (line 49, `"0".."9"`), so exponent digits are decimal.
- The odin-lang.org overview (https://odin-lang.org/docs/overview/) mentions semicolons only for `for` loops and a vet option.

Tooling leniency: no explicit GB statement that tools may be more lenient than the compiler. Unknown. The closest evidence is the tooling framing above.

## 4. Known divergences between `core:odin/parser` and the compiler

Probes below ran in `/tmp/nabla_probe/main.odin` (core parser) and `/tmp/nabla_case/case.odin` and `/tmp/nabla_cases/{a,b,c,d,e}.odin` (compiler). "Compiler" is the fork's C++ compiler, run on the probe files.

| Input | Core, default (`Optional_Semicolons`) | Core, no flags | Compiler |
|---|---|---|---|
| file scope: `invalid :: 1e1f` | accepted, 0 errors, 2 declarations (`invalid :: 1e1`, then `f`; the split is inferred from the decl count) | 2 errors: "expected ';', got identifier" 3:12, "expected ';', got newline" 3:24 | rejected: "Invalid integer literal", 5:12 |
| file scope: `a :: 1 b :: 2` | accepted, 0 errors, 2 declarations | rejected | rejected: "Expected ';', got identifier", 3:7 |
| body: `a := 42 b := 13` | 1 error: "expected ';', got identifier", 4:7 | not run | rejected: "Expected ';', got identifier", 4:9 |
| body: `x := 1e1f` | 1 error | not run | rejected: "Invalid integer literal", 4:7 |
| body: `x := 12abc` | 1 error | not run | rejected: "Expected ';', got identifier", 4:9 |
| struct with newline before `}` | accepted | accepted | accepted |

Divergences, with what GB said:

1. Exponent lexing, the root of `1e1f`. The C++ tokenizer scans the exponent with `scan_mantissa(t, 10, false)`. The `false` argument makes it use base 16, so letters are consumed and `1e1f` is one token (`src/tokenizer.cpp` around lines 479–486 and 603–612). The core tokenizer scans the exponent in base 10 (`core/odin/tokenizer/tokenizer.odin` around lines 541–557), so `1e1` and `f` are two tokens. GB's commit `35651cfc1` (2024-06-28), "Improve tokenization for false integer literals but not effect possible float literals", introduced the `force_base` argument. Its message does not mention exponents. That the change was meant for this case is inference.
2. Same-line statements. The compiler rejects `a :: 1 b :: 2` and `a := 42 b := 13`. The core parser accepts the first at file scope under the default flag, and rejects both inside a body. I did not trace why the scope matters. Issue #1302 reported `a = 42 b = 13` as not detected. Its reporter later said it was fixed. No GB comment is attached. Unknown whether the file-scope result is intended.
3. Newline before `}` in field lists. Fixed by #2649. Both parsers now accept it (probe above).
4. Multi-line `if` conditions. Open: issue #6584 (opened 2026-04-16). PR #6609 is open and says it aligns the core parser with the compiler's behaviour. No GB comment on either.
5. Ternary-style `when` expressions. Open: issue #3816 (opened 2024-06-27). The core parser cannot parse them. No GB comment.
6. Reserved package names. The compiler errors on them. Since `3da173087` the core parser does not check them at all. PR #2565 for an opt-in flag was closed by GB.
7. `12abc`. Both parsers reject it. Listed for completeness.

## 5. Decision for our parser

Decision: our compiler's parser follows the official compiler, not `core:odin/parser`. Reasons: AGENTS.md requires the same program to behave the same under this compiler and the official one. The official compiler is the observed reference, and the 2026 test expects `1e1f` to be an error.

1. `1e1f`: reject it. After the decimal exponent digits, the lexer should keep consuming letters into the same token, as `scan_mantissa(t, 10, false)` does in the C++ tokenizer. The parser then reports "Invalid integer literal". The grammar would also reject the input, through `1e1` followed by `f` with no separator. The two verdicts agree. The message and token boundary should follow the compiler.
2. Semicolons: implement the compiler's generic rule (`src/parser.cpp` lines 2024–2059):
   - An explicit `;` ends the statement.
   - A token on a later line ends it.
   - `}`, `)` or EOF on the same line ends it.
   - Anything else on the same line is an error: "Expected ';', got <token>".
   This needs no per-node table. It matches the 2021 article's "multiple statements per line" rule.
3. Do not copy `Optional_Semicolons` or `is_semicolon_optional_for_node`. They are tooling leniency.
4. Tests: one fixture for `invalid :: 1e1f` (rejected with "Invalid integer literal") and one for `a :: 1 b :: 2` (rejected). The compiler's own test covers the first, so ours guards our lexer and our semicolon rule.

Open for the core maintainers, not for our parser: the file-scope and body inconsistency (section 4, item 2), and the tokenizer boundary (item 1).

## Sources

- Fork history, via `git log` and `git show` in `/home/su3h7am/Projects/Odin`: `54fbdabc3`, `ca4657fd3`, `1eb1bffd8`, `9ccdc40f6`, `1fff96e08`, `50ee65ea9`, `374024fc7`, `edaaa27f8`, `488a38a`, `1945218f6`, `35651cfc1`, `3da173087`, `8181e3564`, `591afb56b`.
- Probe programs in `/tmp/nabla_probe/` and `/tmp/nabla_case/`, `/tmp/nabla_cases/`. Not part of the repository.
- GitHub: https://github.com/odin-lang/Odin/pull/7686, /pull/799, /pull/1112, /pull/1182, /pull/2565, /pull/2649, /pull/6609, /issues/275, /issues/1152, /issues/1302, /issues/3715, /issues/3816, /issues/6584.
- odin-lang.org: https://odin-lang.org/news/optional-semicolons/, https://odin-lang.org/spec/grammar/, https://odin-lang.org/docs/overview/.
- gingerbill.org: https://www.gingerbill.org/article/2020/01/25/a-reply-to-lets-stop-copying-c/, https://www.gingerbill.org/article/2026/02/19/choosing-a-language-based-on-syntax/.

## Unknown

- Whether GB wants `core:odin/parser` to match the compiler exactly. No statement found.
- Whether GB considers tooling allowed to be more lenient. No statement found.
- The reason for the exponent change in `35651cfc1`. Inferred only.
- GB's view on #6584, #6609 and #3816. No comment found.
- Why the core parser accepts `a :: 1 b :: 2` at file scope but rejects it in a body. Observed, not traced.
- The discussion on Discord and the forum about `1e1f`. Not searched in depth.
