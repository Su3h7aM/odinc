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
	store := checker.type_checker.store
	kind := types.get(store, conversion_base_type(store, operand.type)).kind
	valid := conversion_integer(kind) && (unary.op.kind == .Add || unary.op.kind == .Sub || unary.op.kind == .Xor)
	valid ||= conversion_boolean(kind) && unary.op.kind == .Not
	valid ||= conversion_complex(kind) && (unary.op.kind == .Add || unary.op.kind == .Sub)
	valid ||= conversion_float(kind) && (unary.op.kind == .Add || unary.op.kind == .Sub)
	// Official unary plus, minus, and bitwise-not on arrays work element-wise.
	is_array := kind == .Array || kind == .Enumerated_Array
	if is_array {
		element_kind := types.get(store, types.get(store, conversion_base_type(store, operand.type)).elem).kind
		if conversion_integer(element_kind) || conversion_float(element_kind) || conversion_complex(element_kind) {
			valid ||= unary.op.kind == .Add || unary.op.kind == .Sub
		}
		if conversion_integer(element_kind) || conversion_boolean(element_kind) || element_kind == .Bit_Set {
			valid ||= unary.op.kind == .Xor
		}
	}
	// Official unary plus, minus, and bitwise-not on matrices work element-wise. Matrix elements are
	// always numeric, so plus and minus apply; bitwise-not needs integers.
	is_matrix := kind == .Matrix
	if is_matrix {
		element_kind := types.get(store, types.get(store, conversion_base_type(store, operand.type)).elem).kind
		valid ||= unary.op.kind == .Add || unary.op.kind == .Sub
		valid ||= unary.op.kind == .Xor && conversion_integer(element_kind)
	}
	if !valid { return expression_failure(checker, view, scope, node, .Invalid_Operator) }
	info = Expression_Info {
		type  = operand.type,
		mode  = .Value,
		state = .Checked,
		scope = scope,
	}
	// Official constant arrays under a unary operator become runtime values instead of folding.
	if operand.mode == .Constant && !is_array && !is_matrix {
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

conversion_complex :: proc(kind: types.Kind) -> bool {
	return kind == .Complex || kind == .Quaternion || kind == .Untyped_Complex || kind == .Untyped_Quaternion
}

Comparison_Plan :: struct {
	type: types.Type_Id,
}

@(private = "package")
expression_needs_operand_hint :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	operand := node
	for file.ast.nodes[operand].kind == .Paren_Expr {
		operand = syntax.node_payload(file.ast, operand, syntax.Paren_Expr).expr
	}
	#partial switch file.ast.nodes[operand].kind {
	case .Implicit_Selector_Expr:
		return true
	case .Ternary_If_Expr:
		ternary := syntax.node_payload(file.ast, operand, syntax.Ternary_Expr)
		return expression_needs_operand_hint(file, ternary.x) && expression_needs_operand_hint(file, ternary.y)
	case .Comp_Lit:
		return syntax.node_payload(file.ast, operand, syntax.Comp_Lit).type == 0
	}
	return false
}

Binary_Operands :: struct {
	left, right:       Expression_Info,
	binary_conversion: Plan_Id,
	complete:          bool,
}

Binary_Operand_Class :: struct {
	store:                       ^types.Store,
	left_kind:                   types.Kind,
	right_kind:                  types.Kind,
	integer:                     bool,
	bitwise_integer:             bool,
	boolean:                     bool,
	enum_pair:                   bool,
	type_id_pair:                bool,
	string_pair:                 bool,
	pointer_pair:                bool,
	float_side:                  bool,
	float_pair:                  bool,
	union_pair:                  bool,
	struct_pair:                 bool,
	bit_set_pair:                bool,
	procedure_pair:              bool,
	operator:                    syntax.Token_Kind,
	comparison:                  bool,
	shift:                       bool,
	left_base:                   ^types.Type,
	broadcast_pair:              bool,
	array_leaf:                  types.Type_Id,
	nested_broadcast:            bool,
	array_leaf_kind:             types.Kind,
	array_numeric:               bool,
	array_integer:               bool,
	array_bitwise_integer:       bool,
	array_boolean:               bool,
	array_bit_set:               bool,
	array_compare:               bool,
	simd_both:                   bool,
	simd_arithmetic:             bool,
	simd_quotient:               bool,
	simd_bitwise_pair:           bool,
	simd_bitwise_broadcast:      bool,
	complex_pair:                bool,
	quaternion_pair:             bool,
	complex_arithmetic:          bool,
	left_untyped, right_untyped: bool,
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
	operands: Binary_Operands
	info = expression_binary_operands(checker, view, scope, node, hint, &operands) or_return
	if operands.complete { return info, nil }
	classification: Binary_Operand_Class
	classification, info = binary_operand_class(checker, view, scope, node, operands) or_return
	if info.state != .Checked { return info, nil }
	info = expression_binary_validate(checker, view, scope, node, operands, classification) or_return
	if info.state != .Checked { return info, nil }
	info = expression_binary_convert(checker, view, scope, node, hint, &operands, classification) or_return
	if info.state != .Checked { return info, nil }
	return expression_binary_result(checker, view, scope, node, &operands, classification)
}

@(private = "file")
expression_binary_operands :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
	operands: ^Binary_Operands,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	operands.complete = true
	file := checker.type_checker.files[checker.views[view].file]
	binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
	if binary.op.kind == .In || binary.op.kind == .Not_In {
		return expression_membership(checker, view, scope, node, binary.op.kind == .Not_In)
	}
	unwrapped_left := binary.left
	for file.ast.nodes[unwrapped_left].kind == .Paren_Expr {
		unwrapped_left = syntax.node_payload(file.ast, unwrapped_left, syntax.Paren_Expr).expr
	}
	if expression_needs_operand_hint(file, binary.left) && !expression_needs_operand_hint(file, binary.right) {
		operands.right = check_expression(checker, view, scope, binary.right) or_return
		if operands.right.state == .Invalid { return expression_poison(scope), nil }
		operands.left = check_expression(checker, view, scope, binary.left, operands.right.type) or_return
	} else if file.ast.nodes[unwrapped_left].kind == .Ternary_If_Expr &&
	   file.ast.nodes[binary.right].kind != .Ternary_If_Expr &&
	   file.ast.nodes[binary.right].kind != .Implicit_Selector_Expr {
		operands.right = check_expression(checker, view, scope, binary.right) or_return
		if operands.right.state == .Invalid { return expression_poison(scope), nil }
		left_hint := types.Type_Id(0)
		if !conversion_untyped(
			types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, operands.right.type)).kind,
		) { left_hint = operands.right.type }
		operands.left = check_expression(checker, view, scope, binary.left, left_hint) or_return
	} else {
		left_hint := types.Type_Id(0)
		if expression_needs_operand_hint(file, binary.left) || expression_is_auto_cast(file, binary.left) {
			if !(syntax.Token_Kind.B_Comparison_Begin < binary.op.kind && binary.op.kind < .B_Comparison_End) { left_hint = hint }
		}
		if expression_has_runtime_shift(checker, view, scope, file, binary.left) or_return { left_hint = integer_operand_hint(checker, hint) }
		comparison := syntax.Token_Kind.B_Comparison_Begin < binary.op.kind && binary.op.kind < .B_Comparison_End
		if left_hint == 0 && !comparison && expression_length_call(file, binary.left) { left_hint = length_integer_hint(checker, hint) }
		operands.left = check_expression(checker, view, scope, binary.left, left_hint) or_return
		if operands.left.state == .Invalid { return expression_poison(scope), nil }
		right_hint := types.Type_Id(0)
		left_base := types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, operands.left.type)).kind
		if file.ast.nodes[binary.right].kind == .Implicit_Selector_Expr ||
		   operands.left.mode != .Type && expression_string_kind(left_base) && !conversion_untyped(left_base) { right_hint = operands.left.type }
		if expression_needs_operand_hint(file, binary.right) {
			right_hint = operands.left.type
		}
		if expression_is_auto_cast(file, binary.right) {
			right_hint = hint
			if binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq { right_hint = operands.left.type }
			if comparison && binary.op.kind != .Cmp_Eq && binary.op.kind != .Not_Eq { right_hint = 0 }
		}
		if right_hint == 0 && (expression_has_runtime_shift(checker, view, scope, file, binary.right) or_return) {
			if operands.left.mode != .Type && (left_base == .Integer || left_base == .Rune) {
				right_hint = operands.left.type
			} else {
				right_hint = integer_operand_hint(checker, hint)
			}
		}
		if right_hint == 0 && expression_length_call(file, binary.right) {
			if operands.left.mode != .Type && length_integer_hint(checker, operands.left.type) != 0 {
				right_hint = operands.left.type
			} else if !comparison {
				right_hint = length_integer_hint(checker, hint)
			}
		}
		unwrapped_right := binary.right
		for file.ast.nodes[unwrapped_right].kind == .Paren_Expr {
			unwrapped_right = syntax.node_payload(file.ast, unwrapped_right, syntax.Paren_Expr).expr
		}
		if file.ast.nodes[unwrapped_right].kind == .Ternary_If_Expr && !conversion_untyped(left_base) { right_hint = operands.left.type }
		operands.right = check_expression(checker, view, scope, binary.right, right_hint) or_return
	}
	if operands.left.state == .Invalid || operands.right.state == .Invalid { return expression_poison(scope), nil }
	if binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq {
		store := checker.type_checker.store
		if operands.left.mode == .Type && operands.right.mode != .Type && types.get(store, conversion_base_type(store, operands.right.type)).kind == .Type_Id {
			operands.left = expression_typeid_value(checker, scope, operands.left.type) or_return
		}
		if operands.right.mode == .Type && operands.left.mode != .Type && types.get(store, conversion_base_type(store, operands.left.type)).kind == .Type_Id {
			operands.right = expression_typeid_value(checker, scope, operands.right.type) or_return
		}
	}
	if operands.left.mode == .Type && operands.right.mode == .Type && (binary.op.kind == .Cmp_Eq || binary.op.kind == .Not_Eq) {
		value := types.are_identical(checker.type_checker.store, operands.left.type, operands.right.type)
		if binary.op.kind == .Not_Eq { value = !value }
		constant, failure := constant_pool_intern_bool(checker.constants, value, types.TYPE_UNTYPED_BOOL)
		if failure != nil { return {}, expression_constant_failure(checker, checker.views[view].file, node, failure) }
		return Expression_Info{scope = scope, mode = .Constant, type = types.TYPE_UNTYPED_BOOL, constant = constant, state = .Checked}, nil
	}
	if !expression_value(operands.left) || !expression_value(operands.right) { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	if expression_binary_matrix_involved(checker, operands.left, operands.right) {
		return expression_binary_matrix(checker, view, scope, node, binary, operands.left, operands.right, hint)
	}
	operands.complete = false
	return Expression_Info{state = .Checked}, nil
}

@(private = "file")
binary_operand_class :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	operands: Binary_Operands,
) -> (
	classification: Binary_Operand_Class,
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
	store := checker.type_checker.store
	left_descriptor := types.get(store, conversion_base_type(store, operands.left.type))^
	right_descriptor := types.get(store, conversion_base_type(store, operands.right.type))^
	left_kind := left_descriptor.kind
	right_kind := right_descriptor.kind
	integer := conversion_integer(left_kind) && conversion_integer(right_kind)
	integer ||=
		conversion_integer(left_kind) && conversion_untyped(right_kind) && operand_assignable(checker, view, binary.right, operands.right, operands.left.type)
	integer ||=
		conversion_integer(right_kind) && conversion_untyped(left_kind) && operand_assignable(checker, view, binary.left, operands.left, operands.right.type)
	// Official check_binary_op gates `&`, `|` and `~` on core_type, which unwraps an enum to its backing integer.
	left_core_kind := types.get(store, conversion_core_type(store, operands.left.type)).kind
	right_core_kind := types.get(store, conversion_core_type(store, operands.right.type)).kind
	bitwise_integer := conversion_integer(left_core_kind) && conversion_integer(right_core_kind)
	bitwise_integer ||=
		conversion_integer(left_core_kind) &&
		conversion_untyped(right_kind) &&
		operand_assignable(checker, view, binary.right, operands.right, operands.left.type)
	bitwise_integer ||=
		conversion_integer(right_core_kind) &&
		conversion_untyped(left_kind) &&
		operand_assignable(checker, view, binary.left, operands.left, operands.right.type)
	boolean := conversion_boolean(left_kind) && conversion_boolean(right_kind)
	enum_pair := left_kind == .Enum && right_kind == .Enum
	type_id_pair := left_kind == .Type_Id && right_kind == .Type_Id
	string_pair := expression_string_kind(left_kind) && expression_string_kind(right_kind)
	pointer_pair := conversion_pointer(left_kind) && conversion_pointer(right_kind)
	pointer_pair ||= left_kind == .Untyped_Nil && conversion_nilable(right_descriptor) || right_kind == .Untyped_Nil && conversion_nilable(left_descriptor)
	float_side := conversion_float(left_kind) || conversion_float(right_kind)
	float_pair :=
		float_side && (conversion_float(left_kind) || conversion_integer(left_kind)) && (conversion_float(right_kind) || conversion_integer(right_kind))
	union_pair :=
		left_kind == .Union && right_kind == .Union && generator_supported(store, operands.left.type) && generator_supported(store, operands.right.type)
	union_pair ||=
		left_kind == .Union &&
		right_kind != .Union &&
		!conversion_untyped(right_kind) &&
		generator_supported(store, operands.left.type) &&
		operand_assignable(checker, view, binary.right, operands.right, operands.left.type)
	union_pair ||=
		right_kind == .Union &&
		left_kind != .Union &&
		!conversion_untyped(left_kind) &&
		generator_supported(store, operands.right.type) &&
		operand_assignable(checker, view, binary.left, operands.left, operands.right.type)
	// Official comparison converts an untyped operand into the union when it converts into a variant.
	union_pair ||=
		left_kind == .Union &&
		conversion_untyped(right_kind) &&
		right_kind != .Untyped_Nil &&
		generator_supported(store, operands.left.type) &&
		operand_assignable(checker, view, binary.right, operands.right, operands.left.type)
	union_pair ||=
		right_kind == .Union &&
		conversion_untyped(left_kind) &&
		left_kind != .Untyped_Nil &&
		generator_supported(store, operands.right.type) &&
		operand_assignable(checker, view, binary.left, operands.left, operands.right.type)
	struct_pair :=
		left_kind == .Struct &&
		right_kind == .Struct &&
		types.are_identical(store, operands.left.type, operands.right.type) &&
		types.is_comparable(store, operands.left.type) &&
		generator_supported(store, operands.left.type)
	bit_set_pair := left_kind == .Bit_Set && right_kind == .Bit_Set && types.are_identical(store, operands.left.type, operands.right.type)
	procedure_pair := left_kind == .Procedure && right_kind == .Procedure && types.are_identical(store, operands.left.type, operands.right.type)
	operator := binary.op.kind
	comparison := syntax.Token_Kind.B_Comparison_Begin < operator && operator < .B_Comparison_End
	shift := operator == .Shl || operator == .Shr
	if shift && operands.right.mode == .Constant {
		value, ok := constant_pool_get(checker.constants, operands.right.constant).value.(big.Int)
		if ok {
			negative, failure := big.is_negative(&value, allocator = checker.allocator)
			if failure != .None {
				if constant_error := expression_constant_failure(checker, checker.views[view].file, node, Constant_Error(failure));
				   constant_error != nil { return {}, {}, constant_error }
				return {}, expression_poison(scope), nil
			}
			if negative { info, err = expression_failure(checker, view, scope, node, .Invalid_Operand); return {}, info, err }
		}
	}
	array_pair := false
	left_base := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, operands.left.type))
	right_base := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, operands.right.type))
	if left_base.kind == .Array && left_base.kind == right_base.kind && left_base.elem == right_base.elem && left_base.count == right_base.count {
		array_pair = true
	}
	// Official identical enumerated arrays also combine element-wise; the index type is part of the identity.
	if left_base.kind == .Enumerated_Array &&
	   left_base.kind == right_base.kind &&
	   left_base.elem == right_base.elem &&
	   left_base.count == right_base.count &&
	   left_base.index == right_base.index {
		array_pair = true
	}
	// Official array programming: a scalar combines element-wise with an array when the scalar converts to it.
	broadcast_pair := false
	if left_base.kind == .Array && right_base.kind != .Array && operand_assignable(checker, view, binary.right, operands.right, operands.left.type) {
		broadcast_pair = true
	} else if right_base.kind == .Array && left_base.kind != .Array && operand_assignable(checker, view, binary.left, operands.left, operands.right.type) {
		broadcast_pair = true
	}
	// Official array programming gates the operator on the innermost element, like check_binary_op over
	// core_array_type: named wrappers unwrap at every level, matrices and simd vectors do not participate.
	array_side := operands.left.type
	if left_base.kind != .Array && left_base.kind != .Enumerated_Array { array_side = operands.right.type }
	array_leaf := types.Type_Id(0)
	if left_base.kind == .Array || left_base.kind == .Enumerated_Array || right_base.kind == .Array || right_base.kind == .Enumerated_Array {
		leaf := array_side
		for {
			unwrapped := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, leaf))
			if unwrapped.kind != .Array && unwrapped.kind != .Enumerated_Array { break }
			leaf = unwrapped.elem
		}
		array_leaf = types.resolve_named(checker.type_checker.store, leaf)
	}
	// Official array programming also splats a scalar through nested arrays when it converts to the innermost element.
	nested_broadcast := false
	if !array_pair && !broadcast_pair && array_leaf != 0 {
		if left_base.kind == .Array && right_base.kind != .Array && right_base.kind != .Enumerated_Array {
			if operand_assignable(checker, view, binary.right, operands.right, array_leaf) {
				nested_broadcast = true
			}
		} else if right_base.kind == .Array && left_base.kind != .Array && left_base.kind != .Enumerated_Array {
			if operand_assignable(checker, view, binary.left, operands.left, array_leaf) {
				nested_broadcast = true
			}
		}
	}
	array_leaf_kind := types.Kind.Invalid
	if array_leaf != 0 { array_leaf_kind = types.get(checker.type_checker.store, array_leaf).kind }
	array_involved := array_pair || broadcast_pair || nested_broadcast
	array_numeric := array_involved && array_element_numeric(checker.type_checker.store, array_leaf)
	array_integer := array_involved && (array_leaf_kind == .Integer || array_leaf_kind == .Rune)
	// Official bitwise operators unwrap enums to their backing integer through core_type.
	array_bitwise_integer := array_integer || (array_involved && array_element_core_integer(checker.type_checker.store, array_leaf))
	array_boolean := array_involved && array_leaf_kind == .Bool
	array_bit_set := array_involved && array_leaf_kind == .Bit_Set
	array_compare := false
	if array_involved && types.is_comparable(checker.type_checker.store, array_side) {
		array_compare = true
		// Compared arrays of structs or unions compare through the generated equality of their element type,
		// which the generator cannot express for some contents, like scalar comparisons do.
		if array_leaf_kind == .Struct || array_leaf_kind == .Union {
			array_compare = generator_supported(checker.type_checker.store, array_leaf)
		}
	}
	// Official arithmetic and equality on two identical simd vectors works element-wise.
	simd_both := left_base.kind == .Simd_Vector && left_base.kind == right_base.kind
	simd_arithmetic := false
	simd_quotient := false
	if simd_both {
		element_kind := types.get(checker.type_checker.store, left_base.elem).kind
		// Official division is not allowed with integer elements.
		simd_quotient = conversion_float(element_kind)
		simd_arithmetic = simd_quotient || conversion_integer(element_kind)
	}
	simd_element_kind := types.Kind.Invalid
	if left_base.kind == .Simd_Vector {
		simd_element_kind = types.get(store, types.resolve_named(store, left_base.elem)).kind
	} else if right_base.kind == .Simd_Vector {
		simd_element_kind = types.get(store, types.resolve_named(store, right_base.elem)).kind
	}
	simd_integer_element := conversion_integer(simd_element_kind)
	simd_boolean_element := conversion_boolean(simd_element_kind)
	simd_same_type := simd_both && types.are_identical(store, operands.left.type, operands.right.type)
	simd_bitwise_pair := simd_same_type && simd_integer_element
	if operator != .And_Not { simd_bitwise_pair ||= simd_same_type && simd_boolean_element }
	simd_bitwise_broadcast := false
	if operator == .And || operator == .Or || operator == .Xor || operator == .And_Not {
		bitwise_element := simd_integer_element || operator != .And_Not && simd_boolean_element
		if bitwise_element {
			if left_base.kind == .Simd_Vector &&
			   right_base.kind != .Simd_Vector &&
			   operand_assignable(checker, view, binary.right, operands.right, operands.left.type) {
				simd_bitwise_broadcast = true
			} else if right_base.kind == .Simd_Vector &&
			   left_base.kind != .Simd_Vector &&
			   operand_assignable(checker, view, binary.left, operands.left, operands.right.type) {
				simd_bitwise_broadcast = true
			}
		}
	}
	// Official equality on two complex or two quaternion values compares them directly.
	complex_pair := (left_base.kind == .Complex || left_base.kind == .Untyped_Complex) && (right_base.kind == .Complex || right_base.kind == .Untyped_Complex)
	quaternion_pair :=
		(left_base.kind == .Quaternion || left_base.kind == .Untyped_Quaternion) && (right_base.kind == .Quaternion || right_base.kind == .Untyped_Quaternion)
	complex_arithmetic := conversion_complex(left_kind) && conversion_complex(right_kind)
	complex_arithmetic ||=
		conversion_complex(left_kind) && conversion_untyped(right_kind) && operand_assignable(checker, view, binary.right, operands.right, operands.left.type)
	complex_arithmetic ||=
		conversion_complex(right_kind) && conversion_untyped(left_kind) && operand_assignable(checker, view, binary.left, operands.left, operands.right.type)
	complex_arithmetic ||=
		(conversion_complex(left_kind) || conversion_complex(right_kind)) &&
		(conversion_integer(left_kind) || conversion_float(left_kind) || conversion_complex(left_kind)) &&
		(conversion_integer(right_kind) || conversion_float(right_kind) || conversion_complex(right_kind))
	return Binary_Operand_Class {
			store = store,
			left_kind = left_kind,
			right_kind = right_kind,
			integer = integer,
			bitwise_integer = bitwise_integer,
			boolean = boolean,
			enum_pair = enum_pair,
			type_id_pair = type_id_pair,
			string_pair = string_pair,
			pointer_pair = pointer_pair,
			float_side = float_side,
			float_pair = float_pair,
			union_pair = union_pair,
			struct_pair = struct_pair,
			bit_set_pair = bit_set_pair,
			procedure_pair = procedure_pair,
			operator = operator,
			comparison = comparison,
			shift = shift,
			left_base = left_base,
			broadcast_pair = broadcast_pair,
			array_leaf = array_leaf,
			nested_broadcast = nested_broadcast,
			array_leaf_kind = array_leaf_kind,
			array_numeric = array_numeric,
			array_integer = array_integer,
			array_bitwise_integer = array_bitwise_integer,
			array_boolean = array_boolean,
			array_bit_set = array_bit_set,
			array_compare = array_compare,
			simd_both = simd_both,
			simd_arithmetic = simd_arithmetic,
			simd_quotient = simd_quotient,
			simd_bitwise_pair = simd_bitwise_pair,
			simd_bitwise_broadcast = simd_bitwise_broadcast,
			complex_pair = complex_pair,
			quaternion_pair = quaternion_pair,
			complex_arithmetic = complex_arithmetic,
			left_untyped = conversion_untyped(left_kind),
			right_untyped = conversion_untyped(right_kind),
		},
		Expression_Info{state = .Checked},
		nil
}

@(private = "file")
expression_binary_validate :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	operands: Binary_Operands,
	classification: Binary_Operand_Class,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	valid := false
	#partial switch classification.operator {
	case .Add, .Sub:
		valid =
			classification.integer ||
			classification.float_pair ||
			classification.array_numeric ||
			classification.array_bit_set ||
			classification.bit_set_pair ||
			classification.simd_arithmetic ||
			classification.complex_arithmetic
		// Official string concatenation requires constant strings on both sides.
		if classification.operator == .Add &&
		   classification.string_pair &&
		   operands.left.mode == .Constant &&
		   operands.right.mode == .Constant { valid = true }
	case .Mul:
		valid =
			classification.integer ||
			classification.float_pair ||
			classification.array_numeric ||
			classification.simd_arithmetic ||
			classification.complex_arithmetic
	case .Quo:
		valid =
			classification.integer ||
			classification.float_pair ||
			classification.array_numeric ||
			classification.simd_quotient ||
			classification.complex_arithmetic
	case .Mod, .Mod_Mod, .Shl, .Shr:
		valid = classification.integer || (classification.array_integer && (classification.operator == .Mod || classification.operator == .Mod_Mod))
	case .And, .Or, .Xor, .And_Not:
		array_bitwise := classification.array_bitwise_integer || classification.array_bit_set
		if classification.operator != .And_Not { array_bitwise ||= classification.array_boolean }
		valid =
			classification.integer ||
			classification.bitwise_integer ||
			classification.boolean ||
			array_bitwise ||
			classification.bit_set_pair ||
			classification.simd_bitwise_pair ||
			classification.simd_bitwise_broadcast
	case .Cmp_And, .Cmp_Or:
		valid = classification.boolean
	case .Cmp_Eq, .Not_Eq:
		valid =
			classification.integer ||
			classification.boolean ||
			classification.float_pair ||
			classification.enum_pair ||
			classification.type_id_pair ||
			classification.string_pair ||
			classification.pointer_pair ||
			classification.union_pair ||
			classification.struct_pair ||
			classification.array_compare ||
			classification.simd_both ||
			classification.complex_pair ||
			classification.complex_arithmetic ||
			classification.quaternion_pair ||
			classification.bit_set_pair ||
			classification.procedure_pair
	case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		valid =
			classification.integer ||
			classification.float_pair ||
			classification.enum_pair ||
			classification.string_pair ||
			classification.pointer_pair ||
			classification.bit_set_pair
	case .Eq:
		valid = true
	}
	if !valid { return expression_failure(checker, view, scope, node, .Invalid_Operator) }
	return Expression_Info{state = .Checked}, nil
}

@(private = "file")
expression_binary_convert :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	hint: types.Type_Id,
	operands: ^Binary_Operands,
	classification: Binary_Operand_Class,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
	if !classification.shift && !types.are_identical(classification.store, operands.left.type, operands.right.type) {
		target := operands.left.type
		if classification.left_untyped && !classification.right_untyped { target = operands.right.type }
		if classification.left_untyped && classification.right_untyped {
			if classification.integer { target = types.TYPE_UNTYPED_INTEGER }
			if classification.left_kind == .Untyped_Rune || classification.right_kind == .Untyped_Rune { target = types.TYPE_UNTYPED_RUNE }
			if classification.float_side { target = types.TYPE_UNTYPED_FLOAT }
			if classification.left_kind == .Untyped_Complex || classification.right_kind == .Untyped_Complex { target = types.TYPE_UNTYPED_COMPLEX }
			if classification.left_kind == .Untyped_Quaternion || classification.right_kind == .Untyped_Quaternion { target = types.TYPE_UNTYPED_QUATERNION }
		}
		if !classification.left_untyped && !classification.right_untyped {
			if !classification.comparison {
				// Official array programming converts an assignable scalar to the array or SIMD vector type.
				if classification.broadcast_pair || classification.simd_bitwise_broadcast {
					if operand_assignable(checker, view, binary.left, operands.left, operands.right.type) {
						operands.left = expression_conversion(
							checker,
							view,
							scope,
							binary.left,
							expression_value_operand(checker, view, binary.left, operands.left),
							operands.left,
							operands.right.type,
							.Assignment,
						) or_return
					} else if operand_assignable(checker, view, binary.right, operands.right, operands.left.type) {
						operands.right = expression_conversion(
							checker,
							view,
							scope,
							binary.right,
							expression_value_operand(checker, view, binary.right, operands.right),
							operands.right,
							operands.left.type,
							.Assignment,
						) or_return
					} else {
						return expression_failure(checker, view, scope, node, .Mismatched_Types)
					}
				} else {
					if classification.operator != .Cmp_And && classification.operator != .Cmp_Or {
						return expression_failure(checker, view, scope, node, .Mismatched_Types)
					}
					operands.right = expression_conversion(
						checker,
						view,
						scope,
						binary.right,
						expression_value_operand(checker, view, binary.right, operands.right),
						operands.right,
						operands.left.type,
						.Cast,
					) or_return
				}
			} else if operand_assignable(checker, view, binary.left, operands.left, operands.right.type) {
				operands.left = expression_conversion(
					checker,
					view,
					scope,
					binary.left,
					expression_value_operand(checker, view, binary.left, operands.left),
					operands.left,
					operands.right.type,
					.Assignment,
				) or_return
				operands.binary_conversion = Plan_Id(len(checker.plans))
				append(&checker.plans, Plan(Binary_Conversion_Plan{type = operands.right.type, left = operands.left.plan})) or_return
			} else if operand_assignable(checker, view, binary.right, operands.right, operands.left.type) {
				operands.right = expression_conversion(
					checker,
					view,
					scope,
					binary.right,
					expression_value_operand(checker, view, binary.right, operands.right),
					operands.right,
					operands.left.type,
					.Assignment,
				) or_return
				operands.binary_conversion = Plan_Id(len(checker.plans))
				append(&checker.plans, Plan(Binary_Conversion_Plan{type = operands.left.type, right = operands.right.plan})) or_return
			} else if (classification.integer || classification.float_pair || classification.pointer_pair || classification.enum_pair) &&
			   (expression_is_auto_cast(file, binary.left) || expression_is_auto_cast(file, binary.right)) {
				original_left, original_right := operands.left, operands.right
				operands.left, operands.right = expression_auto_cast_comparison(checker, view, scope, node, binary, operands.left, operands.right) or_return
				if operands.left.state == .Invalid || operands.right.state == .Invalid { return expression_poison(scope), nil }
				if operands.left.mode != .Constant || operands.right.mode != .Constant {
					conversions := Binary_Conversion_Plan {
						type = operands.left.type,
					}
					if operands.left.type != original_left.type { conversions.left = operands.left.plan }
					if operands.right.type != original_right.type { conversions.right = operands.right.plan }
					operands.binary_conversion = Plan_Id(len(checker.plans))
					append(&checker.plans, Plan(conversions)) or_return
				}
			} else {
				return expression_failure(checker, view, scope, node, .Mismatched_Types)
			}
		} else {
			if operands.left.type != target && target != types.TYPE_UNTYPED_COMPLEX && target != types.TYPE_UNTYPED_QUATERNION {
				operands.left = check_expression(checker, view, scope, binary.left, target) or_return
			}
			if operands.right.type != target && target != types.TYPE_UNTYPED_COMPLEX && target != types.TYPE_UNTYPED_QUATERNION {
				operands.right = check_expression(checker, view, scope, binary.right, target) or_return
			}
		}
	}
	if classification.shift && classification.left_untyped && operands.right.mode != .Constant {
		target := hint
		if target == 0 { target = checker.default_integer }
		operands.left = check_expression(checker, view, scope, binary.left, target) or_return
	}
	if operands.left.state == .Invalid || operands.right.state == .Invalid { return expression_poison(scope), nil }
	return Expression_Info{state = .Checked}, nil
}

@(private = "file")
expression_binary_result :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	operands: ^Binary_Operands,
	classification: Binary_Operand_Class,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[checker.views[view].file]
	binary := syntax.node_payload(file.ast, node, syntax.Binary_Expr)
	if classification.comparison &&
	   (classification.union_pair || classification.struct_pair) &&
	   (operands.left.mode != .Constant || operands.right.mode != .Constant) {
		compared_type := operands.left.type
		if classification.left_kind != .Union && classification.right_kind == .Union { compared_type = operands.right.type }
		append(&checker.plans, Plan(Comparison_Plan{type = types.resolve_named(classification.store, compared_type)})) or_return
		// The generated equality the comparison lowers through calls runtime helpers for some
		// contents, like cstrings, so they must be resolved even when no map uses them.
		_, helper_error := expression_resolve_map_helpers(checker)
		if helper_error != nil { return {}, helper_error }
	}
	// Compared arrays of structs or unions compare through the generated equality of their element type.
	if classification.comparison &&
	   classification.array_compare &&
	   (classification.array_leaf_kind == .Struct || classification.array_leaf_kind == .Union) &&
	   (operands.left.mode != .Constant || operands.right.mode != .Constant) {
		append(&checker.plans, Plan(Comparison_Plan{type = classification.array_leaf})) or_return
		_, helper_error := expression_resolve_map_helpers(checker)
		if helper_error != nil { return {}, helper_error }
	}
	// A dynamic integer paired with an untyped operand needs concrete rows at both runtime uses.
	if operands.left.mode != .Constant || operands.right.mode != .Constant {
		if conversion_untyped(types.get(classification.store, operands.left.type).kind) {
			left_target := checker.default_integer
			if types.get(classification.store, operands.left.type).kind ==
			   .Untyped_Float { left_target = types.default_type_of_untyped(classification.store, types.TYPE_UNTYPED_FLOAT) }
			operands.left = check_expression(checker, view, scope, binary.left, left_target) or_return
		}
		if conversion_untyped(types.get(classification.store, operands.right.type).kind) {
			target := checker.default_integer
			if types.get(classification.store, operands.right.type).kind ==
			   .Untyped_Float { target = types.default_type_of_untyped(classification.store, types.TYPE_UNTYPED_FLOAT) }
			if !classification.shift { target = operands.left.type }
			operands.right = check_expression(checker, view, scope, binary.right, target) or_return
		}
	}
	if classification.comparison && classification.string_pair && (operands.left.mode != .Constant || operands.right.mode != .Constant) {
		return expression_runtime_comparison(checker, view, scope, node, binary.left, binary.right, classification.operator, operands.left.type)
	}
	result_type := operands.left.type
	if conversion_complex(classification.right_kind) && !conversion_complex(classification.left_kind) { result_type = operands.right.type }
	// Official array programming yields the array type when a scalar broadcasts into it, even an untyped one.
	if classification.simd_bitwise_broadcast {
		result_type = operands.left.type if classification.left_base.kind == .Simd_Vector else operands.right.type
	} else if classification.broadcast_pair || classification.nested_broadcast {
		result_type = operands.left.type if classification.left_base.kind == .Array else operands.right.type
	}
	if classification.left_untyped &&
	   classification.right_untyped &&
	   (classification.left_kind == .Untyped_Quaternion || classification.right_kind == .Untyped_Quaternion) {
		result_type = types.TYPE_UNTYPED_QUATERNION
	}
	info = Expression_Info {
		type  = result_type,
		mode  = .Value,
		state = .Checked,
		scope = scope,
		plan  = operands.binary_conversion,
	}
	if classification.comparison {
		info.type = types.TYPE_UNTYPED_BOOL
		if operands.left.mode != .Constant || operands.right.mode != .Constant { info.type = checker.boolean }
	}
	return expression_binary_constant(checker, view, scope, node, operands, classification, info)
}

@(private = "file")
expression_binary_constant :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	operands: ^Binary_Operands,
	classification: Binary_Operand_Class,
	result: Expression_Info,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	info = result
	if operands.left.mode == .Constant && operands.right.mode == .Constant {
		constant: Const_Id
		failure: Constant_Error
		if classification.comparison {
			// N2's comparison API names equality Eq; parsed equality is Cmp_Eq.
			comparison_operator := classification.operator
			if comparison_operator == .Cmp_Eq { comparison_operator = .Eq }
			// Official subset ordering compares bit patterns with masks, not integer order.
			if (classification.operator == .Lt || classification.operator == .Gt || classification.operator == .Lt_Eq || classification.operator == .Gt_Eq) &&
			   classification.left_kind == .Bit_Set {
				constant, failure = expression_bit_set_ordering(checker, classification.operator, operands.left, operands.right, info.type)
			} else {
				constant, failure = constant_compare_operator(
					checker.constants,
					comparison_operator,
					operands.left.constant,
					operands.right.constant,
					info.type,
				)
			}
		} else {
			constant_operator := classification.operator
			if classification.bit_set_pair {
				if classification.operator == .Add { constant_operator = .Or }
				if classification.operator == .Sub { constant_operator = .And_Not }
			}
			constant, failure = constant_binary_operator(
				checker.constants,
				constant_operator,
				operands.left.constant,
				operands.right.constant,
				info.type,
				.Trap,
				classification.store,
			)
		}
		if failure != nil {
			// Official check_comparison folds only constant types; other constant operands compare at runtime.
			demoted := false
			if classification.comparison {
				if pool_failure, is_pool_failure := failure.(Constant_Pool_Error); is_pool_failure && pool_failure == .Invalid_Operand {
					operands.left.mode, operands.right.mode = .Value, .Value
					demoted = true
				}
			}
			if !demoted {
				expression_constant_failure(checker, checker.views[view].file, node, failure) or_return
				return expression_poison(scope), nil
			}
		} else {
			info.mode, info.constant = .Constant, constant
		}
	}
	return info, nil
}

// Like upstream is_type_numeric over the array core element: integers, floats, complex values, and enums over them.
@(private = "file")
array_element_numeric :: proc(store: ^types.Store, id: types.Type_Id) -> bool {
	if id == 0 { return false }
	descriptor := types.get(store, types.resolve_named(store, id))
	#partial switch descriptor.kind {
	case .Integer, .Rune, .Float, .Complex, .Quaternion:
		return true
	case .Enum:
		return array_element_numeric(store, descriptor.backing)
	}
	return false
}

// Like upstream core_type for bitwise operators: enums unwrap to their backing integer.
@(private = "file")
array_element_core_integer :: proc(store: ^types.Store, id: types.Type_Id) -> bool {
	if id == 0 { return false }
	descriptor := types.get(store, types.resolve_named(store, id))
	if descriptor.kind == .Enum { return array_element_core_integer(store, descriptor.backing) }
	return descriptor.kind == .Integer || descriptor.kind == .Rune
}

// Official bit-set ordering is subset comparison through masks: a <= b holds when (a & b) == a.
@(private = "file")
expression_bit_set_ordering :: proc(
	checker: ^Expression_Checker,
	operator: syntax.Token_Kind,
	left, right: Expression_Info,
	bool_type: types.Type_Id,
) -> (
	id: Const_Id,
	err: Constant_Error,
) {
	store := checker.type_checker.store
	both, and_error := constant_binary_operator(checker.constants, .And, left.constant, right.constant, left.type, .Trap, store)
	if and_error != nil { return 0, and_error }
	anchor := left.constant
	if operator == .Gt || operator == .Gt_Eq { anchor = right.constant }
	included_id, include_error := constant_compare_operator(checker.constants, .Eq, both, anchor, bool_type)
	if include_error != nil { return 0, include_error }
	included := constant_pool_get(checker.constants, included_id).value.(bool)
	if operator == .Lt_Eq || operator == .Gt_Eq {
		return constant_pool_intern_bool(checker.constants, included, bool_type)
	}
	separate_id, separate_error := constant_compare_operator(checker.constants, .Not_Eq, left.constant, right.constant, bool_type)
	if separate_error != nil { return 0, separate_error }
	differ := constant_pool_get(checker.constants, separate_id).value.(bool)
	return constant_pool_intern_bool(checker.constants, included && differ, bool_type)
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

@(private = "file")
integer_operand_hint :: proc(checker: ^Expression_Checker, hint: types.Type_Id) -> types.Type_Id {
	if hint == 0 { return 0 }
	kind := types.get(checker.type_checker.store, conversion_base_type(checker.type_checker.store, hint)).kind
	if kind == .Integer || kind == .Rune { return hint }
	return 0
}

@(private = "package")
expression_has_runtime_shift :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	file: ^File,
	node: syntax.Node_Index,
) -> (
	runtime: bool,
	err: Resolve_Error,
) {
	current := node
	for file.ast.nodes[current].kind == .Paren_Expr {
		current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr
	}
	if file.ast.nodes[current].kind != .Binary_Expr { return false, nil }
	binary := syntax.node_payload(file.ast, current, syntax.Binary_Expr)
	if binary.op.kind == .Shl || binary.op.kind == .Shr {
		count := check_expression(checker, view, scope, binary.right) or_return
		return count.mode != .Constant, nil
	}
	if expression_has_runtime_shift(checker, view, scope, file, binary.left) or_return { return true, nil }
	return expression_has_runtime_shift(checker, view, scope, file, binary.right)
}

@(private = "file")
expression_length_call :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	current := node
	for file.ast.nodes[current].kind == .Paren_Expr {
		current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr
	}
	if file.ast.nodes[current].kind != .Call_Expr { return false }
	callee := syntax.node_payload(file.ast, current, syntax.Call_Expr).expr
	if file.ast.nodes[callee].kind == .Selector_Expr {
		callee = syntax.node_payload(file.ast, callee, syntax.Selector_Expr).field
	}
	if file.ast.nodes[callee].kind != .Ident { return false }
	name := expression_text(file, callee)
	return name == "len" || name == "cap"
}

// Official comparisons and logical operators over comparisons are untyped booleans, which convert to any boolean type.
@(private = "package")
expression_untyped_boolean_source :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	node: syntax.Node_Index,
	info: Expression_Info,
	hint: types.Type_Id,
) -> bool {
	store := checker.type_checker.store
	if info.type == types.TYPE_NONE || hint == types.TYPE_NONE { return false }
	if !conversion_boolean(types.get(store, conversion_base_type(store, info.type)).kind) { return false }
	if !conversion_boolean(types.get(store, conversion_base_type(store, hint)).kind) { return false }
	return expression_untyped_boolean(checker.type_checker.files[checker.views[view].file], node)
}

@(private = "file")
expression_untyped_boolean :: proc(file: ^File, node: syntax.Node_Index) -> bool {
	current := node
	for file.ast.nodes[current].kind == .Paren_Expr {
		current = syntax.node_payload(file.ast, current, syntax.Paren_Expr).expr
	}
	#partial switch file.ast.nodes[current].kind {
	case .Unary_Expr:
		unary := syntax.node_payload(file.ast, current, syntax.Unary_Expr)
		return unary.op.kind == .Not && expression_untyped_boolean(file, unary.expr)
	case .Binary_Expr:
		binary := syntax.node_payload(file.ast, current, syntax.Binary_Expr)
		if binary.op.kind == .Cmp_And || binary.op.kind == .Cmp_Or {
			return expression_untyped_boolean(file, binary.left) && expression_untyped_boolean(file, binary.right)
		}
		return syntax.Token_Kind.B_Comparison_Begin < binary.op.kind && binary.op.kind < .B_Comparison_End
	}
	return false
}
