# Recursive using oracle limitation

The official compiler accepts `Recursive :: struct { using next: ^Recursive }` as a declaration. Building this program, which exposes and reads its field through a using statement, instead crashes the official compiler with a segmentation fault. This was reproduced through `mise run diff-test src/driver/oracle_limits/recursive_using` on 2026-10-20. The declaration without the using invocation builds and runs under both compilers and remains covered in the normal `using_statement` fixture.

This case is outside the differential fixture directory and is not counted as supported differential coverage. Our member traversal detects repeated owners in the existing member path and stops expansion instead of recursing indefinitely. No language rejection rule is inferred from the official crash. Ordinary nonrecursive using aliases retain the original field address and evaluate their operand at each use, as the official compiler's successful probes demonstrate.

This differs from promoting the completed recursive type into another struct. Official rejects `Outer :: struct { using value: Recursive }` because the recursive expansion repeats `next`. The declaration-time validation covers that rejection separately.
