# Lowering contract

`lower_program` borrows the existing `check.Checked_Program`. It initializes its `ir.Module` output in place; the caller must not move that module and destroys it with `ir.module_destroy`. The caller deletes the returned errors with the supplied allocator. Allocation failure destroys the partial module. Any lowering error prevents code generation from that module.

## G1 inputs

- Every evaluated expression and declaration name has a `Checked` row in `expression_info`, with its final type, addressing mode, entity and retained plan or constant. Statement rows may have no type; assignment and return plans are consumed when present.
- `Conversion_Plan.source` identifies the source value, not the conversion expression itself. Scalar conversions use the source's signedness and the retained target type. Unsupported conversion paths are errors.
- `Assignment_Plan` supplies destinations, values and optional per-value conversion ids. Lowering evaluates all destination addresses before values and performs writes last. Blank destinations use entity zero or a `No_Value` expression row.
- Parameter and local entities retain their semantic types and flags. The procedure's typed view identifies the expressions to scan before binding parameters or declaring locals. Explicit address-taking, array slicing, boxing and `By_Pointer` call arguments force addressable storage; aggregates always use slots.
- File policies supplied through `check.sources` are resolved. Dynamic integer division requires a non-`Unspecified` `division_by_zero`. Unchecked dynamic array indexing requires `bounds_check = Disabled` or a retained `Bounds_Plan` with `policy = Disabled`.
- Scalar floating constants are retained as `Float_Value` with final IEEE bits and width. Integer constants are retained as `big.Int`. Exact rational constants, aggregate constants and string blobs remain unsupported.

Layouts are computed serially before procedure workers start. Workers read the type store and layout table without mutating them. Each worker writes only its own function, bindings and errors.

## Missing checker decisions

The model currently has only `File.policy.division_by_zero`; it has no per-expression division policy. If nested directives can change that policy, the checker must expose their resolved effect before lowering can support them.

`Call_Argument` exposes `By_Pointer` through its parameter entity, but does not explicitly identify implicit address-taking for a method receiver or another pointer conversion. Such calls remain unsupported; their final checked representation must identify the addressable source before the pre-pass can classify that local.

`Member_Step` has `type`, `field_index` and `indirect`, but no producer or documented rule establishes which type owns each field or when indirection occurs. Nonempty place and conversion paths remain unsupported rather than assigning those fields a guessed meaning.

The checker boundary verifier is not implemented. Lowering asserts the consumed facts; it does not resolve names, select overloads or infer missing conversions.

## References and validation

The scalar rules follow the fork's `lb_build_expr`, `lb_build_addr`, `lb_emit_conv`, `lb_integer_division`, `lb_integer_modulo`, `lb_srem_safe_divisor` and `lb_emit_signed_floor_mod`. Ginger Bill's merged [PR 5556](https://github.com/odin-lang/Odin/pull/5556) defines the division-by-zero modes. In particular, signed remainder protects `MIN % -1`, while signed division retains the arithmetic fault for `MIN / -1`.

One G1 test lowers checked fixtures through `lower_program` and interprets the resulting functions. It covers the division/remainder zero-mode table, signed remainder boundaries, scalar address aliasing, integer truncation, and indexed access to a local `[6]u8`. The fixtures are not a claim that the unfinished checker can produce those facts yet.
