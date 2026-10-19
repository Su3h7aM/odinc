package check

import "core:mem"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_complex_builtin :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	builtin: Builtin_Id,
	kind: Builtin_Kind,
	arguments: []syntax.Node_Index,
	ellipsis: bool,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if ellipsis { return expression_unsupported(checker, view, scope, node, "Complex_Builtin_Ellipsis") }
	file_id := checker.views[view].file
	store := checker.type_checker.store
	if kind == .Complex || kind == .Quaternion {
		count := 2 if kind == .Complex else 4
		if len(arguments) != count { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		argument_nodes := arguments
		if kind == .Quaternion {
			file := checker.type_checker.files[file_id]
			first_is_field := file.ast.nodes[arguments[0]].kind == .Field_Value
			for argument in arguments {
				if (file.ast.nodes[argument].kind == .Field_Value) != first_is_field {
					return expression_unsupported(checker, view, scope, node, "Quaternion_Mixed_Arguments")
				}
			}
			if first_is_field {
				argument_nodes = make([]syntax.Node_Index, 4, mem.dynamic_arena_allocator(&checker.arena)) or_return
				seen: [4]bool
				for argument in arguments {
					field := syntax.node_payload(file.ast, argument, syntax.Field_Value)
					name := expression_text(file, field.field)
					index := -1
					switch name {
					case "x", "imag":
						index = 0
					case "y", "jmag":
						index = 1
					case "z", "kmag":
						index = 2
					case "w", "real":
						index = 3
					}
					if index < 0 || seen[index] { return expression_unsupported(checker, view, scope, argument, "Quaternion_Field_Name") }
					seen[index] = true
					argument_nodes[index] = field.value
				}
				for index in 0 ..< 4 { if !seen[index] { return expression_failure(checker, view, scope, node, .Invalid_Operand) } }
			}
		}
		values: [4]Expression_Info
		component_type: types.Type_Id
		all_constant := true
		for argument, index in argument_nodes {
			value := check_expression(checker, view, scope, argument) or_return
			if value.state == .Invalid { return expression_poison(scope), nil }
			base := types.get(store, types.resolve_named(store, value.type))
			if base.kind == .Untyped_Integer || base.kind == .Untyped_Rune {
				value = check_expression(checker, view, scope, argument, types.TYPE_UNTYPED_FLOAT) or_return
				if value.state == .Invalid { return expression_poison(scope), nil }
				base = types.get(store, types.resolve_named(store, value.type))
			}
			if value.mode == .Type ||
			   (base.kind != .Float && base.kind != .Untyped_Float) { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
			if base.endianness != .Native { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
			if value.mode != .Constant { all_constant = false }
			if component_type == 0 && base.kind != .Untyped_Float { component_type = value.type }
			values[index] = value
		}
		if component_type != 0 {
			for argument, index in argument_nodes {
				values[index] = check_expression(checker, view, scope, argument, component_type) or_return
				if values[index].state == .Invalid { return expression_poison(scope), nil }
				all_constant &&= values[index].mode == .Constant
			}
		}
		result_type := types.TYPE_UNTYPED_COMPLEX
		if kind == .Quaternion { result_type = types.TYPE_UNTYPED_QUATERNION }
		if component_type != 0 {
			component := types.get(store, types.resolve_named(store, component_type))
			if kind == .Complex {
				if component.count == 2 {result_type = types.intern(store, types.Type{kind = .Complex, count = 4})
				} else if component.count == 4 {result_type = types.intern(store, types.Type{kind = .Complex, count = 8})
				} else if component.count == 8 {result_type = types.intern(store, types.Type{kind = .Complex, count = 16})
				} else { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
			} else {
				if component.count == 2 {result_type = types.intern(store, types.Type{kind = .Quaternion, count = 8})
				} else if component.count == 4 {result_type = types.intern(store, types.Type{kind = .Quaternion, count = 16})
				} else if component.count == 8 {result_type = types.intern(store, types.Type{kind = .Quaternion, count = 32})
				} else { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
			}
		}
		if all_constant {
			constants: [4]Const_Id
			for index := 0; index < count; index += 1 { constants[index] = values[index].constant }
			if kind == .Complex {
				constant, constant_error := constant_pool_intern_complex(checker.constants, Complex_Value{constants[0], constants[1]}, result_type)
				if constant_error !=
				   nil { expression_constant_failure(checker, file_id, node, constant_error) or_return; return expression_poison(scope), nil }
				return Expression_Info{type = result_type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
			}
			constant, constant_error := constant_pool_intern_quaternion(
				checker.constants,
				Quaternion_Value{constants[3], constants[0], constants[1], constants[2]},
				result_type,
			)
			if constant_error != nil { expression_constant_failure(checker, file_id, node, constant_error) or_return; return expression_poison(scope), nil }
			return Expression_Info{type = result_type, constant = constant, mode = .Constant, scope = scope, state = .Checked}, nil
		}
		operands := make([]Operand, count, mem.dynamic_arena_allocator(&checker.arena)) or_return
		for argument, index in argument_nodes { operands[index] = Operand(Expression_Ref{view, argument}) }
		plan := Plan_Id(len(checker.plans))
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
		return Expression_Info{type = result_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	if len(arguments) != 1 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	value := check_expression(checker, view, scope, arguments[0]) or_return
	if value.state == .Invalid { return expression_poison(scope), nil }
	descriptor := types.get(store, types.resolve_named(store, value.type))
	complex := descriptor.kind == .Complex || descriptor.kind == .Untyped_Complex
	quaternion := descriptor.kind == .Quaternion || descriptor.kind == .Untyped_Quaternion
	if kind == .Jmag || kind == .Kmag {if !quaternion { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	} else if kind != .Conj && !complex && !quaternion { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	if kind == .Conj && !complex && !quaternion { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
	if value.mode == .Constant {
		constant := constant_pool_get(checker.constants, value.constant)
		if components, ok := constant.value.(Complex_Value); ok {
			if kind == .Real { return complex_component(checker, scope, components[0], value.type) }
			if kind == .Imag { return complex_component(checker, scope, components[1], value.type) }
			if kind == .Conj {
				negative, failure := constant_unary_operator(checker.constants, .Sub, components[1])
				if failure != nil { expression_constant_failure(checker, file_id, node, failure) or_return; return expression_poison(scope), nil }
				result, constant_error := constant_pool_intern_complex(checker.constants, Complex_Value{components[0], negative}, value.type)
				if constant_error !=
				   nil { expression_constant_failure(checker, file_id, node, constant_error) or_return; return expression_poison(scope), nil }
				return Expression_Info{type = value.type, constant = result, mode = .Constant, scope = scope, state = .Checked}, nil
			}
		}
		if components, ok := constant.value.(Quaternion_Value); ok {
			component_index := 0
			#partial switch kind {
			case .Real:
				component_index = 0
			case .Imag:
				component_index = 1
			case .Jmag:
				component_index = 2
			case .Kmag:
				component_index = 3
			case .Conj:
				for index := 1; index < 4; index += 1 {
					negative, failure := constant_unary_operator(checker.constants, .Sub, components[index])
					if failure != nil { expression_constant_failure(checker, file_id, node, failure) or_return; return expression_poison(scope), nil }
					components[index] = negative
				}
				result, failure := constant_pool_intern_quaternion(checker.constants, components, value.type)
				if failure != nil { expression_constant_failure(checker, file_id, node, failure) or_return; return expression_poison(scope), nil }
				return Expression_Info{type = value.type, constant = result, mode = .Constant, scope = scope, state = .Checked}, nil
			}
			return complex_component(checker, scope, components[component_index], value.type)
		}
	}
	if kind == .Real || kind == .Imag || kind == .Jmag || kind == .Kmag {
		result_type := complex_component_type(store, value.type)
		if value.mode == .Constant { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		plan := Plan_Id(len(checker.plans))
		operands := make([]Operand, 1, mem.dynamic_arena_allocator(&checker.arena)) or_return
		operands[0] = Operand(Expression_Ref{view, arguments[0]})
		append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
		return Expression_Info{type = result_type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
	}
	plan := Plan_Id(len(checker.plans))
	operands := make([]Operand, 1, mem.dynamic_arena_allocator(&checker.arena)) or_return
	operands[0] = Operand(Expression_Ref{view, arguments[0]})
	append(&checker.plans, Plan(Builtin_Plan{builtin = builtin, arguments = operands})) or_return
	return Expression_Info{type = value.type, mode = .Value, plan = plan, scope = scope, state = .Checked}, nil
}

@(private = "file")
complex_component :: proc(
	checker: ^Expression_Checker,
	scope: Scope_Id,
	component: Const_Id,
	aggregate_type: types.Type_Id,
) -> (
	Expression_Info,
	Resolve_Error,
) {
	constant := constant_pool_get(checker.constants, component)
	if constant == nil { return expression_poison(scope), nil }
	return Expression_Info {
			type = constant.type if constant.type != 0 else complex_component_type(checker.type_checker.store, aggregate_type),
			constant = component,
			mode = .Constant,
			scope = scope,
			state = .Checked,
		},
		nil
}

@(private = "file")
complex_component_type :: proc(store: ^types.Store, type: types.Type_Id) -> types.Type_Id {
	descriptor := types.get(store, types.resolve_named(store, type))
	if descriptor.kind == .Untyped_Complex || descriptor.kind == .Untyped_Quaternion { return types.TYPE_UNTYPED_FLOAT }
	if descriptor.kind == .Complex {
		if descriptor.count == 4 { return types.intern(store, types.Type{kind = .Float, count = 2}) }
		if descriptor.count == 8 { return types.intern(store, types.Type{kind = .Float, count = 4}) }
		return types.intern(store, types.Type{kind = .Float, count = 8})
	}
	if descriptor.count == 8 { return types.intern(store, types.Type{kind = .Float, count = 2}) }
	if descriptor.count == 16 { return types.intern(store, types.Type{kind = .Float, count = 4}) }
	return types.intern(store, types.Type{kind = .Float, count = 8})
}
