package check

import "base:runtime"
import "core:mem"
import "oc:syntax"

// A parameter's supplied argument. The value is 0 when the call does not supply the parameter. The position is the
// argument's index in the call, which is its evaluation order: positional arguments first, then named ones in source order.
@(private = "package")
Call_Slot :: struct {
	value:    syntax.Node_Index,
	position: int,
}

// The leading arguments before the first `name = value`.
@(private = "package")
call_positional_count :: proc(file: ^File, arguments: []syntax.Node_Index) -> int {
	for argument, index in arguments {
		if file.ast.nodes[argument].kind == .Field_Value { return index }
	}
	return len(arguments)
}

// Assigns each argument to the parameter it fills, as official check_call_arguments does. Positional arguments fill the
// first positional_limit parameters in order; each `name = value` fills the parameter it names. Returns the reason the
// call is unsupported, or "" when every argument fills a distinct parameter.
@(private = "package")
call_bind_arguments :: proc(file: ^File, arguments: []syntax.Node_Index, names: []string, positional_limit: int, slots: []Call_Slot) -> string {
	positional_count := call_positional_count(file, arguments)
	for argument in arguments[positional_count:] {
		if file.ast.nodes[argument].kind != .Field_Value { return "Call_Positional_After_Named" }
	}
	for index in 0 ..< min(positional_count, positional_limit) {
		slots[index] = Call_Slot {
			value    = arguments[index],
			position = index,
		}
	}
	for position in positional_count ..< len(arguments) {
		field := syntax.node_payload(file.ast, arguments[position], syntax.Field_Value)
		if file.ast.nodes[field.field].kind != .Ident { return "Call_Named_Field" }
		name := expression_text(file, field.field)
		parameter := -1
		for candidate, index in names {
			if candidate == name {
				parameter = index
				break
			}
		}
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
