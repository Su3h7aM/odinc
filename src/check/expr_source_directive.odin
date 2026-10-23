package check

import "core:hash"
import "core:math/big"
import "core:strings"
import "oc:syntax"
import "oc:types"

// `#file`, `#line`, `#directory` and `#location`, constants of the file they appear in; `#location` names the enclosing
// procedure, or the entity it is given.
@(private = "package")
expression_source_directive :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	name: string,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file_id := checker.views[view].file
	file := checker.type_checker.files[file_id]
	if name != "#location" && len(arguments) != 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	switch name {
	case "#file":
		return expression_source_string(checker, view, scope, node, file.path)
	case "#directory":
		directory := file.path
		if slash := strings.last_index_byte(directory, '/'); slash >= 0 { directory = directory[:slash] }
		return expression_source_string(checker, view, scope, node, directory)
	case "#line":
		line, _ := syntax.line_col(file.lines, file.ast.nodes[node].start)
		integer: big.Int
		defer big.destroy(&integer)
		if failure := big.set(&integer, line); failure != nil {
			expression_constant_failure(checker, file_id, node, failure) or_return
			return expression_poison(scope), nil
		}
		constant, constant_error := constant_pool_intern_integer(checker.constants, &integer, types.TYPE_UNTYPED_INTEGER)
		if constant_error != nil {
			expression_constant_failure(checker, file_id, node, constant_error) or_return
			return expression_poison(scope), nil
		}
		return Expression_Info{type = types.TYPE_UNTYPED_INTEGER, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil
	}
	return expression_location(checker, view, scope, node, arguments)
}

@(private = "file")
expression_source_string :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	text: string,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	constant, constant_error := constant_pool_intern_string(checker.constants, text, types.TYPE_UNTYPED_STRING)
	if constant_error != nil {
		expression_constant_failure(checker, checker.views[view].file, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_STRING, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil
}

@(private = "file")
expression_location :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	file_id := checker.views[view].file
	file := checker.type_checker.files[file_id]
	scopes := checker.type_checker.resolver.scopes
	if len(arguments) > 1 || checker.type_checker.collection.runtime_scope == 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	location_entity := scope_lookup_current(scopes, checker.type_checker.collection.runtime_scope, "Source_Code_Location")
	if location_entity == 0 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	if _, resolve_error := resolve_entity(checker.type_checker.resolver, location_entity); resolve_error != nil { return {}, resolve_error }
	type := entity_get(scopes, location_entity).type
	fields := types.get(checker.type_checker.store, types.resolve_named(checker.type_checker.store, type)).fields
	if len(fields) != 4 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }

	path, procedure := file.path, ""
	start := file.ast.nodes[node].start
	lines := file.lines
	if len(arguments) == 1 {
		target := check_expression(checker, view, scope, arguments[0]) or_return
		if target.state == .Invalid { return expression_poison(scope), nil }
		if target.entity == 0 { return expression_failure(checker, view, scope, arguments[0], .Invalid_Operand) }
		entity := entity_get(scopes, target.entity)
		declaration := checker.type_checker.files[entity.declaration.file]
		path, lines, procedure = declaration.path, declaration.lines, entity.name
		start = declaration.ast.nodes[entity.declaration.node].start
	} else {
		for current := scope; current != 0; current = scope_get(scopes, current).parent {
			binding := scope_get(scopes, current)
			if binding.kind != .Procedure { continue }
			procedure_data := entity_get(scopes, binding.owner).data.(Procedure_Data)
			if procedure_data.definition != 0 { procedure_data = entity_get(scopes, procedure_data.definition).data.(Procedure_Data) }
			procedure = procedure_data.source_name
			break
		}
	}
	line, column := syntax.line_col(lines, start)

	elements: [4]Const_Id
	failure: Constant_Error
	elements[0], failure = constant_pool_intern_string(checker.constants, path, fields[0].type)
	if failure == nil { elements[3], failure = constant_pool_intern_string(checker.constants, procedure, fields[3].type) }
	for value, index in ([2]u32{line, column}) {
		if failure != nil { break }
		integer: big.Int
		defer big.destroy(&integer)
		if failure = big.set(&integer, value); failure == nil {
			elements[index + 1], failure = constant_pool_intern_integer(checker.constants, &integer, fields[index + 1].type)
		}
	}
	if failure == nil {
		constant: Const_Id
		constant, failure = constant_pool_intern_aggregate(checker.constants, type, elements[:])
		if failure == nil { return Expression_Info{type = type, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil }
	}
	expression_constant_failure(checker, file_id, node, failure) or_return
	return expression_poison(scope), nil
}

// `#hash(text, kind)`: the hash of a constant string, as the gb library the official compiler uses computes it.
@(private = "package")
expression_hash_directive :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	arguments: []syntax.Node_Index,
) -> (
	info: Expression_Info,
	err: Resolve_Error,
) {
	if len(arguments) != 2 { return expression_failure(checker, view, scope, node, .Invalid_Operand) }
	texts: [2]string
	for argument, index in arguments {
		operand := check_expression(checker, view, scope, argument) or_return
		if operand.state == .Invalid { return expression_poison(scope), nil }
		if operand.mode != .Constant { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		text, is_text := constant_pool_get(checker.constants, operand.constant).value.(string)
		if !is_text { return expression_failure(checker, view, scope, argument, .Invalid_Operand) }
		texts[index] = text
	}
	data := transmute([]byte)texts[0]
	value: u64
	switch texts[1] {
	case "adler32":
		value = u64(hash.adler32(data))
	case "crc32":
		value = u64(hash.crc32(data))
	case "crc64":
		value = hash_crc64_gb(data)
	case "fnv32":
		value = u64(hash.fnv32(data))
	case "fnv64":
		value = hash.fnv64(data)
	case "fnv32a":
		value = u64(hash.fnv32a(data))
	case "fnv64a":
		value = hash.fnv64a(data)
	case "murmur32":
		value = u64(hash.murmur32(data))
	case "murmur64":
		value = hash.murmur64a(data)
	case:
		return expression_failure(checker, view, scope, arguments[1], .Invalid_Operand)
	}
	integer: big.Int
	defer big.destroy(&integer)
	file_id := checker.views[view].file
	if failure := big.set(&integer, value); failure != nil {
		expression_constant_failure(checker, file_id, node, failure) or_return
		return expression_poison(scope), nil
	}
	constant, constant_error := constant_pool_intern_integer(checker.constants, &integer, types.TYPE_UNTYPED_INTEGER)
	if constant_error != nil {
		expression_constant_failure(checker, file_id, node, constant_error) or_return
		return expression_poison(scope), nil
	}
	return Expression_Info{type = types.TYPE_UNTYPED_INTEGER, mode = .Constant, constant = constant, scope = scope, state = .Checked}, nil
}

// gb_crc64 indexes the table of the MSB-first ECMA-182 polynomial with the reflected update, so it matches no standard CRC-64.
@(private = "file")
hash_crc64_gb :: proc(data: []byte) -> u64 {
	ECMA_182 :: u64(0x42f0e1eba9ea3693)
	table: [256]u64
	for &entry, index in table {
		entry = u64(index) << 56
		for _ in 0 ..< 8 {
			entry = entry << 1 ~ (ECMA_182 if entry >> 63 != 0 else 0)
		}
	}
	result := ~u64(0)
	for b in data {
		result = result >> 8 ~ table[(result ~ u64(b)) & 0xff]
	}
	return ~result
}
