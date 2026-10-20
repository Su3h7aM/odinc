package check

import "base:runtime"
import "core:mem"
import "oc:syntax"
import "oc:types"

// A parameter's supplied argument. The value is 0 when the call does not supply the parameter. The position is the
// argument's index in the call, which is its evaluation order: positional arguments first, then named ones in source order.
// The element is the 1-based result of a multi-result call that fills the parameter, or 0 when the value is not one of them.
@(private = "package")
Call_Slot :: struct {
	value:    syntax.Node_Index,
	position: int,
	element:  int,
}

// The leading arguments before the first `name = value`.
@(private = "package")
call_positional_count :: proc(file: ^File, arguments: []syntax.Node_Index) -> int {
	for argument, index in arguments {
		if file.ast.nodes[argument].kind == .Field_Value { return index }
	}
	return len(arguments)
}

// The index of the parameter named `name`, or -1 when no parameter has that name.
@(private = "package")
call_parameter_index :: proc(names: []string, name: string) -> int {
	for candidate, index in names {
		if candidate == name { return index }
	}
	return -1
}

// The result types of each positional argument that is a multi-result call, indexed by argument position. Nil when no
// argument is one, so the common call takes the one-value-per-argument path.
@(private = "package")
call_expansions :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	arguments: []syntax.Node_Index,
) -> (
	expansions: [][]types.Type_Id,
	err: Resolve_Error,
) {
	for argument, position in arguments {
		if file.ast.nodes[argument].kind != .Call_Expr { continue }
		callee := check_expression(checker, view, scope, syntax.node_payload(file.ast, argument, syntax.Call_Expr).expr) or_return
		if callee.state == .Invalid || callee.mode == .Builtin || callee.mode == .Type { continue }
		info := check_expression(checker, view, scope, argument) or_return
		if info.state == .Invalid || info.mode != .No_Value || int(info.plan) >= len(checker.plans) { continue }
		call, is_call := checker.plans[info.plan].(Call_Plan)
		if !is_call || len(call.results) < 2 { continue }
		if expansions == nil {
			expansions = make([][]types.Type_Id, len(arguments), mem.dynamic_arena_allocator(&checker.arena)) or_return
		}
		expansions[position] = call.results
	}
	return expansions, nil
}

// Assigns each argument to the parameter it fills, as official check_call_arguments does. Positional arguments fill the
// first positional_limit parameters in order, and a multi-result call fills one parameter per result, as official
// check_unpack_arguments does. Each `name = value` fills the parameter it names. Returns the reason the call is
// unsupported, or "" when every argument fills a distinct parameter.
@(private = "package")
call_bind_arguments :: proc(
	file: ^File,
	arguments: []syntax.Node_Index,
	names: []string,
	positional_limit: int,
	slots: []Call_Slot,
	expansions: [][]types.Type_Id = nil,
) -> string {
	positional_count := call_positional_count(file, arguments)
	for argument in arguments[positional_count:] {
		if file.ast.nodes[argument].kind != .Field_Value { return "Call_Positional_After_Named" }
	}
	next := 0
	for argument, position in arguments[:positional_count] {
		results: []types.Type_Id
		if expansions != nil { results = expansions[position] }
		for element in 0 ..< max(len(results), 1) {
			if next >= positional_limit { break }
			slots[next] = Call_Slot {
				value    = argument,
				position = position,
				element  = element + 1 if results != nil else 0,
			}
			next += 1
		}
	}
	for position in positional_count ..< len(arguments) {
		field := syntax.node_payload(file.ast, arguments[position], syntax.Field_Value)
		if file.ast.nodes[field.field].kind != .Ident { return "Call_Named_Field" }
		parameter := call_parameter_index(names, expression_text(file, field.field))
		if parameter < 0 { return "Call_Named_Parameter" }
		if slots[parameter].value != 0 { return "Call_Named_Duplicate" }
		slots[parameter] = Call_Slot {
			value    = field.value,
			position = position,
		}
	}
	return ""
}

// The index of the `..T` parameter of a procedure type, or -1 when it has none.
@(private = "package")
procedure_variadic_index :: proc(file: ^File, procedure_type: syntax.Node_Index) -> int {
	params := syntax.node_payload(file.ast, procedure_type, syntax.Proc_Type).params
	if params == 0 { return -1 }
	index := 0
	for field_node in syntax.node_list(file.ast, syntax.node_payload(file.ast, params, syntax.Field_List).list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		if field.type != 0 && file.ast.nodes[field.type].kind == .Ellipsis { return index }
		index += max(int(field.names.count), 1)
	}
	return -1
}

// The parameter names of a generic declaration, one per name in order. A `$T` parameter is named `T`.
@(private = "package")
declared_parameter_names :: proc(file: ^File, params: syntax.Field_List, allocator: mem.Allocator) -> (names: []string, err: runtime.Allocator_Error) {
	list := make([dynamic]string, allocator) or_return
	for field_node in syntax.node_list(file.ast, params.list) {
		field := syntax.node_payload(file.ast, field_node, syntax.Field)
		for name in syntax.node_list(file.ast, field.names) {
			text := expression_text(file, name)
			if file.ast.nodes[name].kind == .Poly_Type {
				text = expression_text(file, syntax.node_payload(file.ast, name, syntax.Poly_Type).type)
			}
			append(&list, text) or_return
		}
	}
	return list[:], nil
}
