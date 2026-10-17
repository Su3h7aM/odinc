package check

import "base:runtime"
import "core:math/big"
import "core:mem"
import "oc:syntax"
import "oc:types"

Expression_Diagnostic_Kind :: enum u8 {
	None,
	Unsupported,
	Undeclared_Name,
	Invalid_Operand,
	Mismatched_Types,
	Invalid_Operator,
	Constant_Operation,
	Conversion,
	Expected_Integer_Constant,
	Invalid_Literal,
	Expected_Boolean_Constant,
}
Expression_Diagnostic :: struct {
	kind:       Expression_Diagnostic_Kind,
	source:     Source_Span,
	conversion: Conversion_Error,
	constant:   Constant_Error,
}

// Owns typed rows, plans and diagnostics. Files, resolver, type checker and constant pool are borrowed.
// Views and plans reserve index zero. Destroy after all consumers of the borrowed Checked_Program.
Expression_Checker :: struct {
	type_checker:    ^Type_Checker,
	constants:       ^Constant_Pool,
	config:          Conversion_Config,
	target_features: []string,
	default_integer: types.Type_Id,
	boolean:         types.Type_Id,
	unchecked_depth: int,
	allocator:       mem.Allocator,
	arena:           mem.Dynamic_Arena,
	views:           [dynamic]Typed_View,
	plans:           [dynamic]Plan,
	packages:        []Package,
	builtin_kinds:   [dynamic]Builtin_Kind,
	type_info_roots: [dynamic]types.Type_Id,
	symbols:         [dynamic]Symbol,
	entity_symbols:  [dynamic]Symbol_Id,
	procedures:      [dynamic]Checked_Procedure,
	globals:         [dynamic]Global,
	diagnostics:     [dynamic]Expression_Diagnostic,
	results:         []types.Type_Id,
	named_results:   []Entity_Id,
	control:         [dynamic]Control_Frame,
	defers:          [dynamic]Defer_Registration,
	defer_depth:     int,
	active_instance: Instance_Id,
}

expression_checker_init :: proc(
	checker: ^Expression_Checker,
	type_checker: ^Type_Checker,
	pool: ^Constant_Pool,
	config: Conversion_Config,
	default_integer, boolean: types.Type_Id,
	allocator: mem.Allocator,
) -> (
	err: runtime.Allocator_Error,
) {
	assert(checker != nil && checker.type_checker == nil && type_checker != nil && pool != nil)
	checker.type_checker, checker.constants, checker.config = type_checker, pool, config
	type_checker.evaluate_boolean = expression_boolean_evaluator
	type_checker.evaluate_default_type = expression_default_type_evaluator
	checker.default_integer, checker.boolean, checker.allocator = default_integer, boolean, allocator
	mem.dynamic_arena_init(&checker.arena, block_allocator = allocator, array_allocator = allocator)
	checker.views.allocator, checker.plans.allocator, checker.diagnostics.allocator = allocator, allocator, allocator
	checker.control.allocator = allocator
	checker.defers.allocator = allocator
	checker.symbols.allocator, checker.entity_symbols.allocator, checker.procedures.allocator = allocator, allocator, allocator
	checker.builtin_kinds.allocator = allocator
	checker.type_info_roots.allocator = allocator
	checker.globals.allocator = allocator
	defer if err != nil { expression_checker_destroy(checker) }
	append(&checker.views, Typed_View{}) or_return
	append(&checker.plans, Plan{}) or_return
	append(&checker.builtin_kinds, Builtin_Kind.None, .Len, .Cap, .Size_Of, .Align_Of, .Min, .Max, .Abs, .Clamp) or_return
	append(&checker.builtin_kinds, Builtin_Kind.Typeid_Of) or_return
	append(&checker.builtin_kinds, Builtin_Kind.Has_Target_Feature) or_return
	return nil
}

expression_checker_destroy :: proc(checker: ^Expression_Checker) {
	if checker == nil { return }
	delete(checker.views)
	delete(checker.plans)
	delete(checker.globals)
	delete(checker.builtin_kinds)
	delete(checker.type_info_roots)
	delete(checker.symbols)
	delete(checker.entity_symbols)
	delete(checker.procedures)
	delete(checker.diagnostics)
	delete(checker.control)
	delete(checker.defers)
	mem.dynamic_arena_destroy(&checker.arena)
	checker^ = {}
}

// Re-publish after checking; growing any pool invalidates its previously exported slice header.
expression_checker_publish :: proc(checker: ^Expression_Checker, program: ^Checked_Program) {
	program.typed_views = checker.views[:]
	program.plan_table = checker.plans[:]
	program.constant_table = checker.constants.values[:]
	program.entities = checker.type_checker.resolver.scopes.entities[:]
	program.scopes = checker.type_checker.resolver.scopes.scopes[:]
	program.type_data = checker.type_checker.store
	program.packages = checker.packages
	program.builtin_kinds = checker.builtin_kinds[:]
}

@(require_results)
expression_file_view :: proc(checker: ^Expression_Checker, file: File_Id) -> (view: View_Id, err: runtime.Allocator_Error) {
	for typed, index in checker.views {
		if typed.file == file && typed.instance == checker.active_instance && file != 0 { return View_Id(index), nil }
	}
	assert(file != 0 && int(file) < len(checker.type_checker.files))
	count := len(checker.type_checker.files[file].ast.nodes)
	allocator := mem.dynamic_arena_allocator(&checker.arena)
	typed := Typed_View {
		file     = file,
		instance = checker.active_instance,
	}
	typed.nodes.types = make([]types.Type_Id, count, allocator) or_return
	typed.nodes.constants = make([]Const_Id, count, allocator) or_return
	typed.nodes.modes = make([]Addressing_Mode, count, allocator) or_return
	typed.nodes.entities = make([]Entity_Id, count, allocator) or_return
	typed.nodes.plans = make([]Plan_Id, count, allocator) or_return
	typed.nodes.scopes = make([]Scope_Id, count, allocator) or_return
	typed.nodes.states = make([]Node_State, count, allocator) or_return
	view = View_Id(len(checker.views))
	append(&checker.views, typed) or_return
	return view, nil
}

@(require_results)
check_expression :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id = 0,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	assert(view != 0 && int(view) < len(checker.views))
	file_id := checker.views[view].file
	file := checker.type_checker.files[file_id]
	assert(node != 0 && int(node) < len(file.ast.nodes))
	program: Checked_Program
	expression_checker_publish(checker, &program)
	info = expression_info(&program, view, node)
	if info.state == .Unseen {
		info = Expression_Info {
			scope = scope,
			state = .Checked,
		}
		#partial switch file.ast.nodes[node].kind {
		case .Ident:
			info = expression_identifier(checker, file_id, scope, node) or_return
		case .Basic_Lit:
			kind := syntax.node_payload(file.ast, node, syntax.Basic_Lit).kind
			if kind == .String {
				info = expression_string_literal(checker, view, file_id, scope, node, hint) or_return
				break
			}
			if kind != .Integer && kind != .Rune && kind != .Float {
				return expression_failure(checker, view, scope, node, .Unsupported)
			}
			untyped := types.TYPE_UNTYPED_INTEGER
			if kind == .Rune { untyped = types.TYPE_UNTYPED_RUNE }
			if kind == .Float { untyped = types.TYPE_UNTYPED_FLOAT }
			literal, literal_error := literal_constant(checker.constants, kind, expression_text(file, node), untyped)
			if literal_error != nil {
				#partial switch failure in literal_error {
				case runtime.Allocator_Error:
					return {}, failure
				case Constant_Error:
					expression_constant_failure(checker, file_id, node, failure) or_return
				case big.Error:
					if failure == .Out_Of_Memory { return {}, runtime.Allocator_Error.Out_Of_Memory }
				}
				return expression_failure(checker, view, scope, node, .Invalid_Literal)
			}
			info.type = untyped
			info.constant, info.mode = literal, .Constant
		case .Paren_Expr:
			info = check_expression(checker, view, scope, syntax.node_payload(file.ast, node, syntax.Paren_Expr).expr) or_return
		case .Pointer_Type, .Multi_Pointer_Type:
			type := type_expression(checker.type_checker, file_id, scope, node, true) or_return
			info = Expression_Info {
				type  = type,
				mode  = .Type,
				scope = scope,
				state = .Checked,
			}
		case .Unary_Expr:
			if syntax.node_payload(file.ast, node, syntax.Unary_Expr).op.kind == .And {
				info = expression_address(checker, view, file_id, scope, node) or_return
			} else {
				info = expression_unary(checker, view, scope, node) or_return
			}
		case .Binary_Expr:
			info = expression_binary(checker, view, scope, node, hint) or_return
		case .Type_Cast:
			conversion := syntax.node_payload(file.ast, node, syntax.Type_Cast)
			target := type_expression(checker.type_checker, file_id, scope, conversion.type, true) or_return
			operand := check_expression(checker, view, scope, conversion.expr) or_return
			kind := Conversion_Kind.Cast
			if conversion.token.kind == .Transmute { kind = .Transmute }
			info = expression_conversion(checker, view, scope, node, Operand(Expression_Ref{view, conversion.expr}), operand, target, kind) or_return
		case .Call_Expr:
			call := syntax.node_payload(file.ast, node, syntax.Call_Expr)
			if file.ast.nodes[call.expr].kind == .Basic_Directive && expression_text(file, call.expr) == "#config" {
				info = expression_config(checker, view, file_id, scope, node, syntax.node_list(file.ast, call.args)) or_return
				break
			}
			callee := expression_callee(checker, view, file_id, scope, call.expr) or_return
			arguments := syntax.node_list(file.ast, call.args)
			if callee.mode == .Builtin {
				info = expression_builtin_call(checker, view, file_id, scope, node, callee, arguments) or_return
			} else if callee.mode == .Value && callee.entity != 0 && is_generic_procedure(checker, callee.entity) {
				info = expression_generic_call(checker, view, file_id, scope, node, callee, arguments, call.ellipsis.kind != .Invalid) or_return
			} else if callee.mode == .Value && callee.entity != 0 && entity_get(checker.type_checker.resolver.scopes, callee.entity).kind == .Procedure {
				info = expression_call(checker, view, file_id, scope, node, callee, arguments, call.ellipsis.kind != .Invalid) or_return
			} else if (callee.mode == .Value || callee.mode == .Variable || callee.mode == .Immutable_Value) && is_procedure_value(checker, callee.type) {
				info = expression_indirect_call(checker, view, scope, node, call.expr, callee, arguments, call.ellipsis.kind != .Invalid) or_return
			} else {
				if callee.mode != .Type || len(arguments) != 1 || call.ellipsis.kind != .Invalid {
					return expression_failure(checker, view, scope, node, .Unsupported)
				}
				operand := check_expression(checker, view, scope, arguments[0]) or_return
				info = expression_conversion(checker, view, scope, node, Operand(Expression_Ref{view, arguments[0]}), operand, callee.type, .Cast) or_return
			}
		case .Index_Expr:
			info = expression_index(checker, view, file_id, scope, node) or_return
		case .Deref_Expr:
			info = expression_deref(checker, view, file_id, scope, node) or_return
		case .Selector_Expr:
			info = expression_selector(checker, view, file_id, scope, node) or_return
		case .Implicit_Selector_Expr:
			info = expression_implicit_selector(checker, view, scope, node, hint) or_return
		case .Implicit:
			info = expression_context(checker, view, file_id, scope, node) or_return
		case .Ternary_When_Expr:
			info = expression_ternary_when(checker, view, file_id, scope, node, hint) or_return
		case .Ternary_If_Expr:
			info = expression_ternary_if(checker, view, file_id, scope, node, hint) or_return
		case .Or_Else_Expr:
			info = expression_or_else(checker, view, file_id, scope, node, hint) or_return
		case .Or_Return_Expr:
			info = expression_or_return(checker, view, file_id, scope, node) or_return
		case .Slice_Expr:
			info = expression_slice(checker, view, file_id, scope, node) or_return
		case .Comp_Lit:
			info = expression_composite(checker, view, file_id, scope, node) or_return
		case:
			return expression_failure(checker, view, scope, node, .Unsupported)
		}
	}
	if hint != 0 && info.state != .Invalid && info.type != hint && info.mode != .Constant && expression_boxes(checker, hint, info.type) {
		// The node keeps its own row as the source; the boxing conversion is returned to the caller.
		expression_store(checker, view, node, info)
		return expression_conversion(checker, view, scope, node, Operand(Expression_Ref{view, node}), info, hint, .Assignment)
	}
	if hint != 0 && info.state != .Invalid && info.type != hint {
		// A constant is its own retained source. Runtime expressions need a separate cast node.
		if info.mode != .Constant {
			return expression_failure(checker, view, scope, node, .Mismatched_Types)
		}
		info = expression_conversion(checker, view, scope, node, Operand(info.constant), info, hint, .Assignment) or_return
	}
	expression_store(checker, view, node, info)
	return info, nil
}

// A runtime value of a non-`any` type assigned to `any` is boxed by a conversion plan.
@(private = "package")
expression_boxes :: proc(checker: ^Expression_Checker, target, source: types.Type_Id) -> bool {
	store := checker.type_checker.store
	return types.get(store, conversion_base_type(store, target)).kind == .Any && types.get(store, conversion_base_type(store, source)).kind != .Any
}

@(private = "package")
expression_boxing_plan :: proc(checker: ^Expression_Checker, plan: Plan_Id) -> Plan_Id {
	if plan == 0 { return 0 }
	conversion, found := checker.plans[plan].(Conversion_Plan)
	if found && conversion.kind == .Box { return plan }
	return 0
}

@(private = "package")
expression_any_boxed :: proc(conversions: []Plan_Id) -> bool {
	for conversion in conversions {
		if conversion != 0 { return true }
	}
	return false
}

expression_store :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index, info: Expression_Info) {
	rows := checker.views[view].nodes
	index := int(node - checker.views[view].first_node)
	rows.types[index], rows.constants[index], rows.modes[index], rows.entities[index] = info.type, info.constant, info.mode, info.entity
	rows.plans[index], rows.scopes[index], rows.states[index] = info.plan, info.scope, info.state
}

@(private = "package")
expression_text :: proc(file: ^File, node: syntax.Node_Index) -> string {
	span := file.ast.nodes[node]
	return string(file.source[span.start:span.end])
}

@(private = "package")
expression_identifier :: proc(
	checker: ^Expression_Checker,
	file: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	resolver := checker.type_checker.resolver
	entity, _ := scope_lookup(resolver.scopes, scope, expression_text(checker.type_checker.files[file], node))
	view := expression_file_view(checker, file) or_return
	if entity == 0 { return expression_failure(checker, view, scope, node, .Undeclared_Name) }
	return expression_entity_info(checker, file, scope, node, entity)
}

@(private = "package")
expression_entity_info :: proc(
	checker: ^Expression_Checker,
	file: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	entity: Entity_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	resolver := checker.type_checker.resolver
	view := expression_file_view(checker, file) or_return
	state: Resolution_State
	if len(resolver.stack) == 0 {
		state = resolve_entity(resolver, entity) or_return
	} else {
		span := checker.type_checker.files[file].ast.nodes[node]
		state = resolve_dependency(resolver, Dependency{entity = entity, kind = .Constant, source = {file, span.start, span.end}}) or_return
	}
	if state == .Invalid {
		return expression_poison(scope), nil
	}
	binding := entity_get(resolver.scopes, entity)
	info = Expression_Info {
		type     = binding.type,
		constant = binding.constant,
		entity   = entity,
		scope    = scope,
		state    = .Checked,
	}
	#partial switch binding.kind {
	case .Constant:
		info.mode = .Constant
	case .Variable:
		info.mode = .Immutable_Value if .Immutable in binding.flags else .Variable
	case .Type_Name:
		info.mode = .Type
	case .Procedure:
		info.mode = .Value
	case .Builtin:
		info.mode = .Builtin
	case:
		return expression_failure(checker, view, scope, node, .Unsupported)
	}
	return info, nil
}

@(private = "package")
expression_conversion :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	source: Operand,
	info: Expression_Info,
	target: types.Type_Id,
	kind: Conversion_Kind,
) -> (
	converted: Expression_Info,
	err: Resolve_Error,
) {
	if info.state == .Invalid || target == types.TYPE_POISON { return expression_poison(scope), nil }
	result, diagnostic, failure := check_conversion(checker.constants, checker.type_checker.store, source, info, target, kind, checker.config)
	if failure != nil {
		expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
		return expression_poison(scope), nil
	}
	if diagnostic != .None {
		span := checker.type_checker.files[checker.views[view].file].ast.nodes[node]
		append(
			&checker.diagnostics,
			Expression_Diagnostic{kind = .Conversion, source = {checker.views[view].file, span.start, span.end}, conversion = diagnostic},
		) or_return
		return expression_poison(scope), nil
	}
	converted = result.info
	converted.plan = Plan_Id(len(checker.plans))
	if result.plan.kind == .Box { expression_record_type_info(checker, info.type) or_return }
	append(&checker.plans, Plan(result.plan)) or_return
	return converted, nil
}

@(private = "package")
expression_poison :: proc(scope: Scope_Id) -> Expression_Info {
	return Expression_Info{type = types.TYPE_POISON, state = .Invalid, scope = scope}
}

@(private = "package")
expression_failure :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	kind: Expression_Diagnostic_Kind,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.views[view].file
	span := checker.type_checker.files[file].ast.nodes[node]
	append(&checker.diagnostics, Expression_Diagnostic{kind = kind, source = {file, span.start, span.end}}) or_return
	info = expression_poison(scope)
	expression_store(checker, view, node, info)
	return info, nil
}

@(private = "package")
expression_constant_failure :: proc(checker: ^Expression_Checker, file: File_Id, node: syntax.Node_Index, failure: Constant_Error) -> Resolve_Error {
	#partial switch failure in failure {
	case runtime.Allocator_Error:
		return failure
	case big.Error:
		if failure == .Out_Of_Memory { return runtime.Allocator_Error.Out_Of_Memory }
	}
	span := checker.type_checker.files[file].ast.nodes[node]
	_, err := append(&checker.diagnostics, Expression_Diagnostic{kind = .Constant_Operation, source = {file, span.start, span.end}, constant = failure})
	return err
}
