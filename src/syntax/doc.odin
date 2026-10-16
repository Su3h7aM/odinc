// Package syntax is the lexical and, later, syntactic front end of the
// pure-Odin Odin compiler.
//
// This package currently provides the tokenizer:
//
//   - `Token_Kind` and `Token` describe tokens as a kind plus a half-open byte
//     range into the source. The text is sliced on demand with `token_text`, so
//     tokens stay small and no string is copied.
//   - `Tokenizer`, created with `init`, scans a source buffer one token at a
//     time with `next`. It performs automatic semicolon insertion.
//   - Lexical errors are returned as values: the tokenizer appends `Error`
//     values, in scan order, to a caller-provided `[dynamic]Error` using the
//     caller's allocator. Skipped comments are recorded the same way.
//   - Bad input never panics. Invalid UTF-8 and malformed literals produce
//     `Invalid` tokens plus `Error` values.
//   - `make_line_table` and `line_col` give `O(log n)` line/column lookup for an
//     offset.
//
// The package depends only on `core`.
package syntax
