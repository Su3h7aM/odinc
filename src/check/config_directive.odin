package check

import "base:runtime"
import "core:math/big"
import "core:strings"
import "oc:syntax"
import "oc:types"

// Official #config(NAME, default): a -define value for NAME replaces the default. Its kind follows the
// official driver's build_param_to_exact_value (dev-2026-10): bool spellings, then numbers, then string.
// Only untyped kinds result; a mismatch surfaces at the use site.
@(private = "package")
expression_config :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	file_id: File_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file := checker.type_checker.files[file_id]
	if len(arguments) != 2 || file.ast.nodes[arguments[0]].kind != .Ident {
		return expression_unsupported(checker, view, scope, node, "Config_Arguments")
	}
	defaulted := check_expression(checker, view, scope, arguments[1]) or_return
	if defaulted.mode != .Constant { return expression_unsupported(checker, view, scope, node, "Config_Default") }
	name := expression_text(file, arguments[0])
	value, defined := checker.defines[name]
	if !defined { return defaulted, nil }
	id, type, failure := config_constant(checker.constants, value)
	if failure != nil {
		return {}, expression_constant_failure(checker, file_id, node, failure)
	}
	return Expression_Info{type = type, constant = id, mode = .Constant}, nil
}

@(private = "file")
config_constant :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, type: types.Type_Id, err: Constant_Error) {
	if strings.equal_fold(text, "true") || strings.equal_fold(text, "t") {
		id, err = constant_pool_intern_bool(pool, true, types.TYPE_UNTYPED_BOOL)
		return id, types.TYPE_UNTYPED_BOOL, err
	}
	if strings.equal_fold(text, "false") || strings.equal_fold(text, "f") {
		id, err = constant_pool_intern_bool(pool, false, types.TYPE_UNTYPED_BOOL)
		return id, types.TYPE_UNTYPED_BOOL, err
	}
	number, number_type, is_number, number_error := config_number(pool, text)
	if number_error != nil { return 0, 0, number_error }
	if is_number { return number, number_type, nil }
	value := text
	if len(text) > 1 && text[0] == '\'' && text[len(text) - 1] == '\'' { value = text[1:len(text) - 1] }
	id, err = constant_pool_intern_string(pool, value, types.TYPE_UNTYPED_STRING)
	return id, types.TYPE_UNTYPED_STRING, err
}

// Mirrors the official dispatch: a leading sign or digit is required; text with '.' or '-' and an
// exponent is a float; text with an exponent but no '.' or '-' goes to the integer parser, which
// reads the exponent and does not accept '+'; other text is an integer, a base-prefixed integer
// (unsigned only), or a signed decimal.
@(private = "file")
config_number :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, type: types.Type_Id, ok: bool, err: Constant_Error) {
	if len(text) == 0 || !(text[0] == '-' || text[0] == '+' || config_is_digit(text[0])) { return 0, 0, false, nil }
	if config_looks_like_float(text) {
		if strings.contains_rune(text, '.') || strings.contains_rune(text, '-') { return config_float(pool, text) }
		if text[0] == '+' { return 0, 0, false, nil }
		return config_integer_literal(pool, text)
	}
	if len(text) > 2 && text[0] == '0' && strings.index_byte("bodzx", text[1]) >= 0 {
		return config_integer_literal(pool, text)
	}
	digits := text
	negative := text[0] == '-'
	if negative { digits = text[1:] }
	if !config_is_decimal(digits) { return 0, 0, false, nil }
	if !negative { return config_integer_literal(pool, digits) }
	parsed, _, parsed_ok, parse_error := config_integer_literal(pool, digits)
	if parse_error != nil || !parsed_ok { return 0, 0, parsed_ok, parse_error }
	value := constant_pool_get(pool, parsed).value.(big.Int)
	negated: big.Int
	big.int_neg(&negated, &value, allocator = pool.allocator) or_return
	id, err = constant_pool_intern_integer(pool, &negated, types.TYPE_UNTYPED_INTEGER)
	return id, types.TYPE_UNTYPED_INTEGER, true, err
}

@(private = "file")
config_integer_literal :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, type: types.Type_Id, ok: bool, err: Constant_Error) {
	literal, literal_error := literal_constant(pool, .Integer, text, types.TYPE_UNTYPED_INTEGER)
	if literal_error != nil { return config_literal_failure(literal_error) }
	return literal, types.TYPE_UNTYPED_INTEGER, true, nil
}

@(private = "file")
config_float :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, type: types.Type_Id, ok: bool, err: Constant_Error) {
	float_text := text
	if !strings.contains_rune(text, '.') {
		exponent := strings.index_any(text, "eE")
		concatenated, concatenate_error := strings.concatenate({text[:exponent], ".0", text[exponent:]}, context.temp_allocator)
		if concatenate_error != nil { return 0, 0, false, concatenate_error }
		float_text = concatenated
	}
	literal, literal_error := literal_constant(pool, .Float, float_text, types.TYPE_UNTYPED_FLOAT)
	if literal_error != nil { return config_literal_failure(literal_error) }
	return literal, types.TYPE_UNTYPED_FLOAT, true, nil
}

// Allocation failures stop the build; any other literal failure means the text is not a number.
@(private = "file")
config_literal_failure :: proc(literal_error: Literal_Error) -> (id: Const_Id, type: types.Type_Id, ok: bool, err: Constant_Error) {
	#partial switch failure in literal_error {
	case runtime.Allocator_Error:
		return 0, 0, false, failure
	case big.Error:
		if failure == .Out_Of_Memory { return 0, 0, false, runtime.Allocator_Error.Out_Of_Memory }
	}
	return 0, 0, false, nil
}

@(private = "file")
config_looks_like_float :: proc(text: string) -> bool {
	if strings.contains_rune(text, '.') { return true }
	unsigned := text
	if text[0] == '-' || text[0] == '+' { unsigned = text[1:] }
	if len(unsigned) > 1 && unsigned[0] == '0' && !config_is_digit(unsigned[1]) { return false }
	return strings.contains_any(text, "eE")
}

@(private = "file")
config_is_decimal :: proc(text: string) -> bool {
	if len(text) == 0 { return false }
	for character in transmute([]u8)text {
		if !config_is_digit(character) && character != '_' { return false }
	}
	return true
}

@(private = "file")
config_is_digit :: proc(character: u8) -> bool {
	return character >= '0' && character <= '9'
}
