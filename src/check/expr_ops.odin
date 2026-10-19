package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

@(private = "package")
expression_unary :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	unary := syntax.node_payload(file.ast, node, syntax.Unary_Expr)
	operand := check_expression(checker, view, scope, unary.expr) or_return
	if operand.state == .Invalid { return expression_poison(scope), nil }
	if !expression_value(operand) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	kind := types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, operand.type)).kind
	valid := conversion_integer(kind) && (unary.op.kind == .Add || unary.op.kind == .Sub || unary.op.kind == .Xor)
	valid ||= conversion_boolean(kind) && unary.op.kind == .Not
	valid ||= conversion_float(kind) && (unary.op.kind == .Add || unary.op.kind == .Sub)
	if !valid { return expression_failure(checker, view, scope, node, .Invalid_Operator) }
	info = Expression_Info {
		type  = operand.type,
		mode  = .Value,
		state = .Checked,
		scope = scope,
	}
	if operand.mode == .Constant {
		constant, failure := constant_unary_operator(checker.constants, unary.op.kind, operand.constant, operand.type, checker.type_checker.store)
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		info.mode, info.constant = .Constant, constant
	}
	return info, nil
}

// Runtime union comparisons share one generated equality procedure per type, like map keys.
// An operand is assignable to the other operand's type when its value converts, as official convert_to_typed.
@(private = "package")
operand_assignable :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index, info: Expression_Info, target: types.Type_Id) -> bool {
	_, diagnostic, failure := check_conversion(
		checker.constants,
		checker.type_checker.store,
		Operand(Expression_Ref{view, node}),
		info,
		target,
		.Assignment,
		checker.config,
	)
	return failure == nil && diagnostic == .None
}

Comparison_Plan :: struct {
	type: types.Type_Id,
}

@(private = "package")
expression_binary :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
	if binary.op.kind == .In || binary.op.kind == .Not_In {
		return expression_membership(checker, view, scope, node, binary.op.kind == .Not_In)
	}
	left, right: Expression_Info
	unwrapped_left := binary.left
	for file.ast.nodes[unwrapped_left].kind == .Paren_Expr {
		unwrapped_left = syntax.node_payload(file.ast, unwrapped_left, syntax.Paren_Expr).expr
	}
	if file.ast.nodes[binary.left].kind == .Implicit_Selector_Expr && file.ast.nodes[binary.right].kind != .Implicit_Selector_Expr {
		right = check_expression(checker, view, scope, binary.right) or_return
		if right.state == .Invalid { return expression_poison(scope), nil }
		left = check_expression(checker, view, scope, binary.left, right.type) or_return
	} else if file.ast.nodes[unwrapped_left].kind == .Ternary_If_Expr &&
	   file.ast.nodes[binary.right].kind != .Ternary_If_Expr &&
	   file.ast.nodes[binary.right].kind != .Implicit_Selector_Expr {
		right = check_expression(checker, view, scope, binary.right) or_return
		if right.state == .Invalid { return expression_poison(scope), nil }
		left_hint := types.Type_Id(0)
		if !conversion_untyped(
			types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, right.type)).kind,
		) { left_hint = right.type }
		left = check_expression(checker, view, scope, binary.left, left_hint) or_return
	} else {
		left = check_expression(checker, view, scope, binary.left) or_return
		right_hint := types.Type_Id(0)
		left_base := types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, left.type)).kind
		if file.ast.nodes[binary.right].kind == .Implicit_Selector_Expr || expression_string_kind(left_base) { right_hint = left.type }
		is_equality := binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq
		if is_equality && file.ast.nodes[binary.right].kind == .Comp_Lit && syntax.node_payload(file.ast, binary.right, syntax.Comp_Lit).type == 0 {
			right_hint = left.type
		}
		unwrapped_right := binary.right
		for file.ast.nodes[unwrapped_right].kind == .Paren_Expr {
			unwrapped_right = syntax.node_payload(file.ast, unwrapped_right, syntax.Paren_Expr).expr
		}
		if file.ast.nodes[unwrapped_right].kind == .Ternary_If_Expr && !conversion_untyped(left_base) { right_hint = left.type }
		right = check_expression(checker, view, scope, binary.right, right_hint) or_return
	}
	if left.state == .Invalid || right.state == .Invalid { return expression_poison(scope), nil }
	if binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq {
		store := checker.type_checker.store
		if left.mode == .Type && right.mode != .Type && types.get(store, conversion_base_type(store, right.type)).kind == .Type_Id {
			left = expression_typeid_value(checker, scope, left.type) or_return
		}
		if right.mode == .Type && left.mode != .Type && types.get(store, conversion_base_type(store, left.type)).kind == .Type_Id {
			right = expression_typeid_value(checker, scope, right.type) or_return
		}
	}
	if left.mode == .Type && right.mode == .Type && (binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq) {
		value := left.type == right.type
		if binary.op.kind == .Not_Eq { value = !value }
		constant, failure := constant_pool_intern_bool(checker.constants, value, types.TYPE_UNTYPED_BOOL)
		if failure != nil { return {}, expression_constant_failure(checker, checker.views[view].file, node, failure) }
		return Expression_Info{scope = scope, mode = .Constant, type = types.TYPE_UNTYPED_BOOL, constant = constant, state = .Checked}, nil
	}
	if !expression_value(left) || !expression_value(right) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	store := checker.type_checker.store
	left_descriptor := types.get(store, conversion_base_type(store, left.type))^
	right_descriptor := types.get(store, conversion_base_type(store, right.type))^
	left_kind := left_descriptor.kind
	right_kind := right_descriptor.kind
	integer := conversion_integer(left_kind) && conversion_integer(right_kind)
	integer ||= conversion_integer(left_kind) && conversion_untyped(right_kind) && operand_assignable(checker, view, binary.right, right, left.type)
	integer ||= conversion_integer(right_kind) && conversion_untyped(left_kind) && operand_assignable(checker, view, binary.left, left, right.type)
	boolean := conversion_boolean(left_kind) && conversion_boolean(right_kind)
	enum_pair := left_kind == .Enum && right_kind == .Enum
	type_id_pair := left_kind == .Type_Id && right_kind == .Type_Id
	string_pair := expression_string_kind(left_kind) && expression_string_kind(right_kind)
	pointer_pair := conversion_pointer(left_kind) && conversion_pointer(right_kind)
	pointer_pair ||= left_kind == .Untyped_Nil && conversion_nilable(right_descriptor) || right_kind == .Untyped_Nil && conversion_nilable(left_descriptor)
	float_side := conversion_float(left_kind) || conversion_float(right_kind)
	float_pair :=
		float_side && (conversion_float(left_kind) || conversion_integer(left_kind)) && (conversion_float(right_kind) || conversion_integer(right_kind))
	union_pair := left_kind == .Union && right_kind == .Union && generator_supported(store, left.type) && generator_supported(store, right.type)
	struct_pair :=
		left_kind == .Struct &&
		right_kind == .Struct &&
		left.type == right.type &&
		types.is_comparable(store, left.type) &&
		generator_supported(store, left.type)
	operator := binary.op.kind
	comparison := syntax.Token_Kind.B_Comparison_Begin < operator && operator < .B_Comparison_End
	shift := operator == .Shl || operator == .Shr
	if shift && right.mode == .Constant {
		value, ok := constant_pool_get(checker.constants, right.constant).value.(big.Int)
		if ok {
			negative, failure := big.is_negative(&value, allocator = checker.allocator)
			if failure != .None {
				expression_constant_failure(checker, checker.views[view].file, node, Constant_Error(failure)) or_return
				return expression_poison(scope), nil
			}
			if negative { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
		}
	}
	valid := false
	array_pair := false
	left_base := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, left.type))
	right_base := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, right.type))
	if left_base.kind == .Array && left_base.kind == right_base.kind && left_base.elem == right_base.elem && left_base.count == right_base.count {
		array_pair = true
	}
	#partial switch operator {
	case .Add, .Sub, .Mul, .Quo:
		valid = integer || float_pair || array_pair
	case .Mod, .Mod_Mod, .Shl, .Shr:
		valid = integer || (array_pair && (operator == .Mod || operator == .Mod_Mod || operator == .Shl || operator == .Shr))
	case .And, .Or, .Xor, .And_Not:
		valid = integer || boolean || array_pair
	case .Cmp_And, .Cmp_Or:
		valid = boolean
	case .Cmp_Eq, .Not_Eq:
		valid = integer || boolean || float_pair || enum_pair || type_id_pair || string_pair || pointer_pair || union_pair || struct_pair || array_pair
	case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		valid = integer || float_pair || enum_pair || string_pair || pointer_pair || array_pair
	case .Eq:
		valid = true
	}
	if !valid { return expression_failure(checker, view, scope, node, .Invalid_Operator) }
	left_untyped, right_untyped := conversion_untyped(left_kind), conversion_untyped(right_kind)
	if !shift && left.type != right.type {
		target := left.type
		if left_untyped && !right_untyped { target = right.type }
		if left_untyped && right_untyped {
			if integer { target = types.TYPE_UNTYPED_INTEGER }
			if left_kind == .Untyped_Rune || right_kind == .Untyped_Rune { target = types.TYPE_UNTYPED_RUNE }
			if float_side { target = types.TYPE_UNTYPED_FLOAT }
		}
		if !left_untyped && !right_untyped {
			if !comparison { return expression_failure(checker, view, scope, node, .Mismatched_Types) }
			if operand_assignable(checker, view, binary.left, left, right.type) {
				left = expression_conversion(
					checker,
					view,
					scope,
					binary.left,
					expression_value_operand(checker, view, binary.left, left),
					left,
					right.type,
					.Assignment,
				) or_return
			} else if operand_assignable(checker, view, binary.right, right, left.type) {
				right = expression_conversion(
					checker,
					view,
					scope,
					binary.right,
					expression_value_operand(checker, view, binary.right, right),
					right,
					left.type,
					.Assignment,
				) or_return
			} else {
				return expression_failure(checker, view, scope, node, .Mismatched_Types)
			}
		} else {
			if left.type != target {
				left = check_expression(checker, view, scope, binary.left, target) or_return
			}
			if right.type != target {
				right = check_expression(checker, view, scope, binary.right, target) or_return
			}
		}
	}
	if shift && left_untyped && right.mode != .Constant {
		target := hint
		if target == 0 { target = checker.default_integer }
		left = check_expression(checker, view, scope, binary.left, target) or_return
	}
	if left.state == .Invalid || right.state == .Invalid { return expression_poison(scope), nil }
	if comparison && (union_pair || struct_pair) && (left.mode != .Constant || right.mode != .Constant) {
		append(&checker.plans, Plan(Comparison_Plan{type = types.resolve_named(store, left.type)})) or_return
	}
	// A dynamic integer paired with an untyped operand needs concrete rows at both runtime uses.
	if left.mode != .Constant || right.mode != .Constant {
		if conversion_untyped(types.get(store, left.type).kind) {
			left_target := checker.default_integer
			if types.get(store, left.type).kind == .Untyped_Float { left_target = types.default_type_of_untyped(store, types.TYPE_UNTYPED_FLOAT) }
			left = check_expression(checker, view, scope, binary.left, left_target) or_return
		}
		if conversion_untyped(types.get(store, right.type).kind) {
			target := checker.default_integer
			if types.get(store, right.type).kind == .Untyped_Float { target = types.default_type_of_untyped(store, types.TYPE_UNTYPED_FLOAT) }
			if !shift { target = left.type }
			right = check_expression(checker, view, scope, binary.right, target) or_return
		}
	}
	if comparison && string_pair && (left.mode != .Constant || right.mode != .Constant) {
		return expression_runtime_comparison(checker, view, scope, node, binary.left, binary.right, operator, left.type)
	}
	info = Expression_Info {
		type  = left.type,
		mode  = .Value,
		state = .Checked,
		scope = scope,
	}
	if comparison {
		info.type = types.TYPE_UNTYPED_BOOL
		if left.mode != .Constant || right.mode != .Constant { info.type = checker.boolean }
	}
	if left.mode == .Constant && right.mode == .Constant {
		constant: Const_Id
		failure: Constant_Error
		if comparison {
			// N2's comparison API names equality Eq; parsed equality is Cmp_Eq.
			comparison_operator := operator
			if comparison_operator == .Cmp_Eq { comparison_operator = .Eq }
			constant, failure = constant_compare_operator(checker.constants, comparison_operator, left.constant, right.constant, info.type)
		} else {
			constant, failure = constant_binary_operator(checker.constants, operator, left.constant, right.constant, info.type, .Trap, store)
		}
		if failure != nil {
			expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
			return expression_poison(scope), nil
		}
		info.mode, info.constant = .Constant, constant
	}
	return info, nil
}

@(private = "package")
expression_value :: proc(info: Expression_Info) -> bool {
	return(
		info.mode == .Constant ||
		info.mode == .Variable ||
		info.mode == .Immutable_Value ||
		info.mode == .Value ||
		info.mode == .Optional_Ok ||
		info.mode == .Map_Index \
	)
}
