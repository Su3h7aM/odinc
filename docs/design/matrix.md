# Matrix types: design

Status: design only. No compiler change is made by this document. Each stage in section 9 needs orchestrator approval before implementation.

Reference: official compiler dev-2026-10 at `/home/su3h7am/Projects/Odin`. Every accept/reject and layout fact below is an official-compiler probe unless marked as source reading or open. Probe sources are under `/tmp/cs18/` and are not in the repository.

## 1. Layout and storage

Probe `/tmp/cs18/layout/main.odin` measured size, alignment and element byte deltas, and offsets inside `struct {lead: u8, value: T, tail: u8}`.

| Type | Size | Align | Column-major deltas (row, column) | Row-major size | Row-major align | Row-major deltas (row, column) |
| --- | ---: | ---: | --- | ---: | ---: | --- |
| `matrix[3,3]f32` | 36 | 4 | 4, 12 | 36 | 4 | 12, 4 |
| `matrix[2,3]f64` | 48 | 16 | 8, 16 | 48 | 8 | 24, 8 |
| `matrix[4,4]f32` | 64 | 16 | 4, 16 | 64 | 16 | 16, 4 |
| `matrix[3,2]f32` | 24 | 4 | 4, 12 | 24 | 8 | 8, 4 |
| `matrix[1,3]f32` | 12 | 4 | 4 (column) | 12 | 4 | column delta 4 |
| `matrix[2,2]complex64` | 32 | 16 | 8, 16 | not probed | | |

Wrapper offsets: `matrix[3,3]f32` has value at 4, tail at 40, size 44. `matrix[2,3]f64` column-major has value at 16, tail at 64, size 80. Row-major has value at 8, tail at 56, size 64.

Rule: there is no padding between or after storage vectors. The storage vector length is `R` for column-major and `C` for row-major. Stride is `element_size * storage_length`. Size is `stride * other_count`. Alignment is the element alignment raised to the largest power-of-two divisor of the stride, capped at 16. The existing `.Matrix` branch of `layout_internal` (`src/types/types.odin`, about line 459) and official `matrix_type_stride_in_bytes` and `matrix_align_of` (`types.cpp` 1649 onward) follow this rule. Probes confirm it for every shape above, so no layout change is expected for these shapes.

Default storage is column-major. A `#row_major` matrix stores each row contiguously. A literal `matrix[2,3]i32{1,2,3,4,5,6}` is written in logical row order, and its physical element order for the default layout is `[1,4,2,5,3,6]`.

`intrinsics.matrix_flatten` preserves physical order. Probe: default `matrix[2,3]i32` gives `[1,4,2,5,3,6]`; `#row_major` gives `[1,2,3,4,5,6]`.

`intrinsics.transpose` keeps the row-major flag. Probe: transposing a `#row_major` 2x3 matrix gives a 3x2 matrix with `type_is_matrix_row_major == true`, printed `matrix[1, 4; 2, 5; 3, 6]`.

Earlier assumption, now withdrawn: a 3x3 `f32` matrix does not pad its columns. The 36-byte size disproves it.

## 2. Indexing

Open: the element type of `m[k]` for a single index, and the row-major meaning of `m[i]`, are not probed. Section 8 lists the probe needed before stage M2.

Probe: a matrix constant cannot be indexed at compile time. `A :: matrix[2,2]f32{1,2,3,4}; #assert(A[1,0] == 3)` is rejected with `'A[1, 0] == 3' is not a constant boolean`.

Probe: `len` and `cap` on a matrix are rejected.

Probe: `#force_no_inline` is the accepted directive in this Odin version. `@(no_inline)` is rejected as an unknown attribute.

*** End Patch
Probe: `#force_no_inline` is the accepted directive in this Odin version. `@(no_inline)` is rejected as an unknown attribute.

## 3. Element and dimension rules

Element types accepted: integer, float, complex. Probes: `matrix[2,2]bool` rejected; `matrix[2,2]quaternion128` rejected; `matrix[2,2]complex64` accepted.

Dimensions: each is at least 1. The element count (product) is at most 64, so `matrix[8,8]f32` is accepted, `matrix[1,65]f32` and `matrix[0,2]f32` are rejected. Source reading: `MATRIX_ELEMENT_COUNT_MIN = 1`, `MATRIX_ELEMENT_COUNT_MAX = 64`, `types.cpp` 410 to 414. The 16-element limit from the 2021 pull request is out of date.

Scalar initialization: only a square matrix accepts one scalar, giving a scaled identity. `matrix[2,2]i32 = 2` gives `[2,0; 0,2]`. The rectangular form is rejected with `Only a square matrix types can be initialized with a scalar value`.

## 4. Operators (official accept/reject)

Source of the table: 108 official probes `/tmp/cs18/operator_N/main.odin` with index `/tmp/cs18/operators.json`, checked with `odin check`, plus the `check_binary_matrix` reading in `check_expr.cpp`.

| Operator | Integer matrix | Float matrix | Complex matrix |
| --- | --- | --- | --- |
| `+ - *` | accept | accept | accept |
| `/ % %%` | reject | reject | reject |
| `& \| ~ &~` | accept | reject | reject |
| `<< >>` | reject | reject | reject |
| `== !=` | accept | accept | accept |
| `< <= > >= && \|\|` | reject | reject | reject |
| unary `+ -` | accept | accept | accept |
| unary `~` | accept | reject | reject |

Shift example: `a << u32(1)` is rejected with `Shifted operand 'a' must be an integer`.

Matrix with matrix:

1. `+ - ==` and `!=` require identical matrix types.
2. `*` is the matrix product. Probe: `matrix[2,3]f32 * matrix[3,4]f32` accepted, result `matrix[2,4]`. Probe: `matrix[64,1] * matrix[1,64]` rejected (product size 4096 exceeds 64).

Matrix with array:

1. `matrix[2,3] * [3]f32` accepted (array is a column vector).
2. `[2]f32 * matrix[2,3]` accepted (array is a row vector).

Matrix with scalar (probes from the operator and semantics runs):

1. `a * scalar` with `scalar: i32` a typed variable is rejected: `Mismatched types in binary matrix expression`.
2. `scalar * a` with `scalar: i32` is accepted.
3. `a + scalar` and `scalar + a` with typed scalar are rejected.
4. `a + 2`, `2 + a`, `a * 2`, `2 * a` with untyped constants are accepted.
5. `a == scalar` and `a == 2` are accepted. `a < 2` is rejected.

### 4.1 Scalar multiply with a typed constant left operand: confirmed official bug

Stable reproducer (`/tmp/cs20/r/q_fm/main.odin`, three runs): with `m = matrix[2,2]i32{1,2,3,4}`, `i32(3) * m` and `C * m` (`C :: i32(3)`) both give `matrix[3,0;0,3]`, while `3 * m` (untyped) and `t * m` (`t: i32` variable) both give the correct `matrix[3,6;9,12]`.

Defect: in `check_binary_matrix` (`src/check_expr.cpp:4603`), the scalar-left `*` path sets `x->type` to the matrix type but leaves the stale scalar `ExactValue` and constant mode in place. The backend short-circuits the whole node on that recorded value (`lb_build_expr_internal`, `llvm_backend_expr.cpp:4667`, `tv.value.kind != ExactValue_Invalid`), materializing the scalar as a scaled-identity constant and never emitting the multiply. The sibling branch for a matrix left operand sets `x->mode = Addressing_Value` explicitly; the scalar path does not. Constness-dependent arithmetic has no basis in the language: the variable and untyped forms multiply.

Our rule: every accepted scalar left `*` broadcasts, including typed constants. No differential fixture can match official here, so the cell is covered by exit-code verification outside the harness and stays excluded from `matrix_ops_int`.

### 4.2 Float reduction trees: same-output contract

Per-element tree selection, mirroring `lb_is_matrix_simdable` (`llvm_backend_expr.cpp:741`), `lb_emit_matrix_mul` (`:1015`), `lb_emit_matrix_mul_vector` (`:1264`), `lb_emit_vector_mul_matrix` (`:1342`) and the scalar `lb_emit_mul_add` loops (`:1230`, `:1283`, `:1364`):

- Square even products (either layout, when simdable): pairwise reduction with odd carry (`llvm_vector_mul_pairwise_reduce_add`, `llvm_backend_utility.cpp:2329`).
- Simdable non-square products (either layout): shuffle reduction (`llvm_vector_reduce_add`, `:2231`, with `llvm_vector_shuffle_reduction`, `:2189` and zero-padded `llvm_vector_expand_to_power_of_two`, `:2216`).
- Anything else (unaligned, odd x odd, row-major vector products, complex, f16 on amd64, non-native endianness): k-ascending `mul` then `add`, matching the scalar loop.

Simdable means native-endian 32/64-bit float elements, 16-byte matrix alignment, and at least one even dimension. The contract is scoped to the supported amd64 target with default features: generated official IR on this machine shows plain `fmul`/`fadd` chains (no `llvm.fma`: the `fma` target feature is off by default), identical outputs at `-o:none`, `-o:minimal`, `-o:speed` and `-o:aggressive`, and no FMA node or fusion in our backend, so the trees above are emission-specified, not optimizer artifacts. Integers are exact under any tree and stay k-ascending. Fixture `matrix_product_tree` locks each tree with cancellation values that distinguish them.

Known official bug, not reproduced: the row-major non-square SIMD path indexes the right-hand matrix with the left stride (`llvm_backend_expr.cpp:1195`, `offset = x_stride*j + i`, against `y_stride` in the column-major path at `:1144`). Lane-shifted values result at `-o:none` and NaNs at default opts for every element type; integer probes read out-of-bounds lanes. Our lowering addresses both layouts correctly and produces the specified dot values, verified by exit code where differential testing cannot apply.

### 4.3 Evaluation order and side effects

Operand calls evaluate left to right exactly once: the unary dispatch runs before its operand is lowered, and each binary operand lowers once up front. For the probed binary shape, element loads follow both calls: the official probe (`left_root()^ + right_root()^`, right call storing 100 into the left field) reads order counters 0 then 1 and sums the mutated value (110, not 11). Our lowering matches this shape by resolving both operand addresses first and loading each element in the result loop; no broader laziness claim is made beyond the probe. Fixture `matrix_side_effects` locks the counts, the order, and the lazy left read.

f16 matrix negation is zero-minus, unlike scalar f16 negation. Official: scalar `-(f16 0)` gives `-Inf` for the reciprocal (sign flip), but matrix `-h` keeps `+0` (`1 / neg_half[0,0]` is `+Inf`), matching `0 - v` through the existing widen/subtract/narrow helper. Nonzero elements still flip. Fixture `matrix_side_effects` checks the `+Inf` reciprocal and a nonzero lane.

## 5. Casts and transmute

Accepted:

- square to square of another size: the top-left submatrix is kept when shrinking; the rest is identity when growing. Probe: `(matrix[3,3]f32)(matrix[2,2]f32{1,2,3,4})` gives `[1,2,0; 3,4,0; 0,0,1]`.
- `(matrix[1,1]f32)(small)` accepted.
- element cast with the same shape: `(matrix[2,2]f64)(matrix[2,2]f32)` accepted.
- reshape between shapes with the same element count: `(matrix[3,2]i32)(m)` from `matrix[2,3]i32` gives `matrix[1,5; 4,3; 2,6]` (physical order preserved).
- `transmute` between matrix and array of the same byte size: `transmute([4]f32)a` for `matrix[2,2]f32` accepted.

Rejected:

- matrix to array cast: `([4]f32)(a)` for `matrix[2,2]f32`; `([3]f32)(a)` for `matrix[3,1]f32`.
- array to matrix cast: `(matrix[2,2]f32)([4]f32)`; `(matrix[3,1]f32)([3]f32)`.
- `(matrix[3,2]f32)(a)` for `a: matrix[2,3]f32`: accepted on two runs (section 8, item 3). The earlier rejection is not reproduced.

Matrix and array conversions go through `transmute` only. Stage M5 covers it.

## 6. Intrinsics

Official `base:intrinsics`: `transpose`, `outer_product`, `hadamard_product`, `matrix_flatten`, `conj` (complex). Predicates: `type_is_matrix`, `type_is_matrix_row_major`, `type_is_matrix_column_major`, `type_is_valid_matrix_elements`. Our `src/check/builtins.odin` already maps `matrix_flatten` (line 169) and the four predicates (lines 349 to 386). The `transpose`, `outer_product`, `hadamard_product` and `conj` mappings were not checked in this pass.

Source reading (`check_builtin.cpp`): `transpose` 5166, `hadamard_product` 5297, `matrix_flatten` 5343.

`core:math/linalg` procedures (`determinant`, `inverse`, `adjugate`) are ordinary Odin code. Probe: `linalg.determinant(matrix[2,2]f32{4,7,2,6})` is 10; `linalg.inverse` gives `matrix[0.6, -0.7; -0.2, 0.4]`. They need only the primitives above.

Not probed yet: `conj`, `outer_product` result type, `transpose` of an array, `hadamard_product` typing.

*** End Patch
## 7. Lowering and ABI

Lowering strategy (stage M3 onward): the scalar loop form first. Each element is computed by an explicit loop over `k`, ascending, with `acc = acc + a * b` and no FMA contraction. SIMD and LLVM vector forms are a later stage, and they must keep the same `k`-ascending order.

Storage access: a matrix value is a flat array of storage vectors. Element `(row, column)` for column-major is at storage index `column` and element index `row`. For `#row_major` the roles swap. Lowering uses the layout offsets from section 1, so no separate layout is introduced.

Current lowering: `src/lower/lower_operator.odin` `lower_binary` (about line 9) has no matrix branch and fails with `.Operator` for matrix kinds. `src/lower/lower_generated.odin` already handles `.Matrix` in its stride and element count sites (lines 81 and 122). Stage M3 touches only the matrix branch; the `src/lower/lower_range*.odin`, `lower_map*.odin` and `lower_bounds.odin` files stay with agent-158.

ABI, from the official LLVM IR probe `/tmp/cs18/abi/matrix_probe.ll` built with `odin build -build-mode:llvm-ir -no-entry-point`:

| Procedure shape | Official IR classification |
| --- | --- |
| `matrix[1,1]f32` | `float` |
| `matrix[1,3]f32` | `{<2 x float>, float}` |
| `matrix[2,2]f32` | `{<2 x float>, <2 x float>}` |
| `matrix[3,3]f32` | memory: sret `[9 x float]`, byval align 8 |
| `matrix[2,2]i32` | `{i64, i64}` |
| `matrix[2,2]f64` | `{double, double}` |
| `matrix[2,3]f64` | memory: sret `[6 x double]`, byval align 16 |
| `#row_major matrix[2,3]f64` | sret `[6 x double]`, byval align 8 |
| `#row_major matrix[2,2]f32` | `{<2 x float>, <2 x float>}` |

The `contextless` and default-context variants do not change the classification. This is an IR fact, not a behaviour test. Gate before stage M4: a runtime probe passes and returns each shape by value and the results compare equal to the official build. No LLDB is used for this.

Our `src/types/abi_plan.odin` and ABI tests are owned by the orchestrator. This design does not change them. The matrix rows above are the input the orchestrator needs for its ABI plan.

## 8. Probe results (CS19, official dev-2026-10, `odin check -file`)

Probe sources are under `/tmp/cs19/`.

1. Index element type: `m: matrix[2,3]f32; m[1]` has type `[2]f32` (column storage vector, length R). `#row_major matrix[2,3]f32; m[1]` has type `[3]f32` (row, length C). Assigning to the other length is rejected with `Cannot assign value 'm[1]' of type ... in a variable declaration`. Assigning to a scalar `f32` is rejected the same way.
2. Row-major `m[i]`: the row, as item 1.
3. Cast `(matrix[3,2]f32)(a)` with `a: matrix[2,3]f32`: accepted on two separate runs (`cast1`, `cast1b`). The earlier rejection was not reproduced. Stable result: accept. Physical-order reshape is the semantics in section 5.
4. `intrinsics.conj` is not declared. `conj` is a builtin procedure, not an intrinsic. `conj(m)` for `matrix[2,2]complex64` is accepted and the result assigns to `matrix[2,2]complex64`. `conj(m)` for `matrix[2,2]f32` is rejected with `Expected a complex or quaternion, got 'matrix[2, 2]f32'`.
5. `intrinsics.outer_product(a: [2]f32, b: [3]f32)` is accepted and assigns to `matrix[2,3]f32`. With mismatched element types (`[2]f32`, `[3]f64`) it is rejected with `'outer_product' mismatched element types, got f32 vs f64`.
6. `intrinsics.hadamard_product(a, b)` with `a`, `b` of `matrix[2,2]f32` is accepted; the result assigns to `matrix[2,2]f32`. Mismatched types (`matrix[2,2]f32`, `matrix[2,3]f32`) are rejected with `'hadamard_product' values of the same type, got ...`.
7. `intrinsics.transpose(a)` for a plain array `a: [3]f32` is accepted and has type `[3]f32`; assigning it to `matrix[3,1]f32` is rejected. `transpose(a)` for `matrix[2,3]f32` assigns to `matrix[3,2]f32`.
8. Still open: scalar multiply `i32(3) * (2*identity)` confirmation (divergence, pending); runtime ABI behaviour gate (section 7); complex `matrix[2,2]complex64` row-major layout.

## 8.1 Probe results (CS20, official dev-2026-10, `odin check` and `odin run -file`)

Probe sources are under `/tmp/cs20/`.

1. Keyed literals: keys are logical row-major flat indices, not storage indices. Column-major `matrix[2,3]i32{1 = 5}` stores raw `[0, 0, 5, 0, 0, 0]` and reads `m[0,1] == 5`. `#row_major` with key 1 stores raw `[0, 5, 0, 0, 0, 0]`. Out of range (`6` for 6 elements, `-1`), duplicates (`1 = 1, 1 = 2`) and non-constant keys are rejected.
2. Typed scalar `==`: `a == s` and `s == a` with `s: i32` are accepted for `matrix[2,2]i32`; values follow the scalar-init rule (diagonal 2 compares true).
3. Unary `+` and `-` are accepted on integer and float matrices. Unary `~` is accepted on integer matrices and rejected on float matrices. Official codegen of `~` on a matrix fails in LLVM (`Both operands to a binary operator are not of the same type`), so no `~` fixture is kept.
4. Rectangular matrices reject untyped scalars: `m + 2` and `m * 2` for `matrix[2,3]i32` fail conversion, because only a square matrix converts from a scalar.
5. Vector-shape results convert to arrays only through a type hint: `m * v` has type `matrix[2,1]f32` and assigns to `[2]f32`, but not to `[3]f32`. A `matrix[2,2]f32 * [2]f32` product keeps the array type when the hint matches.
6. Runtime indices `m[i,j]` and `m[i]` are accepted. Single-index `m[k]` on a `#row_major` matrix is the row (item 1 of section 8).

## 9. Staged plan

Each stage has its own fixtures under `src/driver/testdata/matrix_*` and a differential run against the official build. Fixtures use integer or exactly representable float values only.

- M1 types and layout: `matrix[R,C]E` type, dimension and element validation, layout (section 1). Fixtures: sizes and offsets of the probed shapes. Checker tests for section 3 rejections.
- M2 literals, indexing, scalar initialization: `m[i,j]` read with constant and runtime indices, `m[k]` storage vectors (section 8 items 1 and 2, section 8.1 item 6), keyed literals with logical keys (section 8.1 item 1). Fixtures: `matrix_literal_index`, `matrix_literal_keyed`, `matrix_index_vector`. Square scalar init (section 3) is still open.
- M3 element-wise operators and scalar broadcast: implemented. `+ - * & | ~ &~ == !=`, unary `+ - ~`, typed scalar rules (`M * t` rejected, `t * M` broadcast, `+ -` typed rejected, `==` typed accepted), untyped scalar conversion to the matrix type (square only). Scalar semantics: `*` broadcasts, every other operator reads the scalar on the diagonal and zero elsewhere, matching `lb_emit_arith_matrix`. Fixtures: `matrix_ops_int`, `matrix_ops_float` (exact values), `matrix_compare`. Unary `~` on integer matrices is accepted by the official checker, but official codegen crashes on it (`Both operands to a binary operator are not of the same type!`, `/tmp/cs20` probe), so no differential fixture can cover it; ours lowers it as xor -1 per element and the values were verified by exit code outside the harness.
- M4 matrix product, matrix with array, array with matrix: implemented per section 4 (reduction trees of section 4.2; row-major flag must match; 64-element result limit). Fixtures: integer, exact-float and complex64 products in `matrix_ops_int`, `matrix_ops_float` and `matrix_product_tree`. The ABI gate (section 7) for matrix arguments and results across procedure boundaries is still open: fixtures only combine values inside one procedure.
- M4 matrix product, matrix with array, array with matrix: implemented per section 4 (reduction trees of section 4.2; row-major flag must match; 64-element result limit). Fixtures: integer, exact-float and complex64 products in `matrix_ops_int`, `matrix_ops_float` and `matrix_product_tree`. The ABI gate (section 7) for matrix arguments and results across procedure boundaries is still open: fixtures only combine values inside one procedure. File-scope matrix globals with composite initializers are explicitly unsupported (`lower Unsupported Global_Initializer`); the side-effect fixture keeps matrices in locals and no full matrix support is claimed.
- M5 casts and transmute (section 5), after open item 3.
- M6 intrinsics: `transpose`, `matrix_flatten`, `hadamard_product`, `outer_product`, `conj`, after open item 4. `transpose` keeps the row-major flag; `matrix_flatten` gives physical order.
- M7 `core:math/linalg` usage fixture (determinant, inverse) on exact values.

Burndown: `docs/burndown.md` gets a matrix section with the reduction-tree contract, the confirmed scalar-multiply bug (section 4.1), and open items 1 to 7.

Histogram groups affected: `12 type Unsupported_Type_Expression Matrix_Type` (M1) and `3 Matrix_Index_Expr` (M2).

## 10. Decisions summary

- Layout: zero padding as probed; no layout change for probed shapes.
- Float: per-element reduction trees of section 4.2, no FMA on the supported target; integers exact under any tree.
- Scalar multiply: broadcast for every accepted scalar side, including typed constants; the official typed-constant-left fold to scaled identity is a confirmed checker bug (section 4.1).
- Transmute is the only matrix-array route; ordinary casts stay rejected.
- `matrix_flatten` physical order; `transpose` keeps row-major.

