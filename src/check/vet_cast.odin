package check

import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Follows the official check_cast and check_transmute with forbid_identical, which only the explicit `cast(T)x` and
// `transmute(T)x` forms set. Bodies of generic instances are skipped, as the official checker skips generic procedures.
@(private = "package")
vet_conversion :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	node: syntax.Node_Index,
	operand_node: syntax.Node_Index,
	kind: Conversion_Kind,
	operand: Operand,
	source: Expression_Info,
	target: types.Type_Id,
) -> Resolve_Error {
	file_id := checker.views[view].file
	if .Cast not_in file_vet(checker, file_id) || checker.active_instance != 0 { return nil }
	store := checker.type_checker.store
	source_base := conversion_base_type(store, source.type)
	if conversion_untyped(types.get(store, source_base).kind) { return nil }
	file := checker.type_checker.files[file_id]
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	target_text := types.type_text(store, target, allocator)
	if kind == .Cast {
		if source.type != target { return nil }
		reason := fmt.aprintf("Unneeded cast of '%s' to identical type '%s'", expression_to_string(file, operand_node), target_text, allocator = allocator)
		return report_conversion(checker, file_id, operand_node, reason)
	}
	if source.mode == .Constant { return nil }
	_, castable, _ := check_conversion(checker.constants, store, operand, source, target, .Cast, checker.config)
	if castable != .None { return nil }
	target_base := conversion_base_type(store, target)
	unneeded := fmt.aprintf("Unneeded transmute of '%s' to identical type '%s'", expression_to_string(file, node), target_text, allocator = allocator)
	source_core := types.get(store, source_base)
	target_core := types.get(store, target_base)
	reason: string
	switch {
	case source.type == target:
		reason = unneeded
	case pointer_like(source_core.kind) && pointer_like(target_core.kind):
		reason = "Use of 'transmute' where 'cast' would be preferred since the types are pointer-like"
	case source_base == target_base:
		reason = unneeded
	case conversion_integer(source_core.kind) && conversion_integer(target_core.kind) && source_core.endianness == target_core.endianness:
		reason = fmt.aprintf(
			"Use of 'transmute' where 'cast' would be preferred since both are integers of the same endianness, from '%s' to '%s'",
			types.type_text(store, source.type, allocator),
			target_text,
			allocator = allocator,
		)
	case:
		return nil
	}
	return report_conversion(checker, file_id, node, reason)
}

@(private = "file")
pointer_like :: proc(kind: types.Kind) -> bool {
	return kind == .Pointer || kind == .Multi_Pointer || kind == .CString || kind == .CString16 || kind == .Procedure
}

@(private = "file")
report_conversion :: proc(checker: ^Expression_Checker, file_id: File_Id, node: syntax.Node_Index, reason: string) -> Resolve_Error {
	span := checker.type_checker.files[file_id].ast.nodes[node]
	source := Source_Span{file_id, span.start, span.end}
	for existing in checker.diagnostics {
		if existing.kind == .Unneeded_Cast && existing.source == source { return nil }
	}
	append(&checker.diagnostics, Expression_Diagnostic{kind = .Unneeded_Cast, source = source, reason = reason}) or_return
	return nil
}
