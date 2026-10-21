package check

import "oc:syntax"
import "oc:types"

@(private = "package")
expression_type_merge :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 2 || ellipsis { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	store := checker.type_checker.store
	unions: [2]types.Type
	for argument, index in arguments {
		operand := type_query_operand(checker, view, scope, argument) or_return
		if operand.state == .Invalid { return expression_poison(scope), nil }
		if operand.mode != .Type { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		unions[index] = types.get(store, types.resolve_named(store, operand.type))^
		if unions[index].kind != .Union { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		if unions[index].union_form == .Maybe_Pointer { unions[index].union_form = .Tagged }
	}
	if unions[0].union_form != unions[1].union_form { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	variants := make([]types.Type_Id, len(unions[0].variants) + len(unions[1].variants), checker.type_checker.arena_allocator) or_return
	count := 0
	for union_type in unions {
		for variant in union_type.variants {
			duplicate := false
			for previous in variants[:count] {
				if types.are_identical(store, previous, variant) { duplicate = true; break }
			}
			if !duplicate { variants[count] = variant; count += 1 }
		}
	}
	form := unions[0].union_form
	if form == .Tagged && count == 1 {
		#partial switch types.get(store, types.resolve_named(store, variants[0])).kind {
		case .Pointer, .Multi_Pointer, .Raw_Pointer, .Procedure:
			form = .Maybe_Pointer
		}
	}
	merged := types.intern(
		store,
		types.Type{kind = .Union, variants = variants[:count], union_form = form, custom_align = max(unions[0].custom_align, unions[1].custom_align)},
	)
	return Expression_Info{type = merged, mode = .Type, scope = scope, state = .Checked}, nil
}
