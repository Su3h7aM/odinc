package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
expressions_check_parsed_scalars_and_constant_dependent_types :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
Count :: (2 + 4)
Buffer :: [Count]u8
byte: u8 = 5
next := byte + 1
letter :: u8('a')
negative: i8 : -128
same :: Count == 6
ready := byte < 9 && !false
shifted := 1 << byte
bits :: (3 | 4) &~ 2
quotient :: -7 / 3
remainder :: -7 %% 3
pointer: ^u8
address := uintptr(pointer)
restored := cast(^u8)address
reinterpreted := transmute(u8)negative
Overflow: u8 : 256
Bad :: 1 / 0
Missing :: unknown + 1
Wrong :: true + 1
Mismatch := byte + negative
Negative_Shift := byte << -1
Flipped :: ~u8(0)
Complement_Untyped :: ~5
`,
	)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return }
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, name = "int", count = 8, signed = true})
	byte_type := types.intern(&store, types.Type{kind = .Integer, count = 1})
	signed_byte := types.intern(&store, types.Type{kind = .Integer, count = 1, signed = true})
	word := types.intern(&store, types.Type{kind = .Integer, name = "uintptr", count = 8})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, scope_error := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, scope_error == nil) { return }
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, package_error == nil && file_error == nil) { return }
	builtins := []struct {
		name: string,
		type: types.Type_Id,
	}{{"int", integer}, {"u8", byte_type}, {"i8", signed_byte}, {"uintptr", word}, {"bool", boolean}}
	for builtin in builtins {
		id, create_error := entity_create(&scopes, Entity{name = builtin.name, kind = .Type_Name, scope = universe, state = .Resolved, type = builtin.type})
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, create_error == nil && insert_error == nil) { return }
	}
	boolean_values := []bool{false, true}
	for value in boolean_values {
		constant, constant_error := constant_pool_intern_bool(&pool, value, types.TYPE_UNTYPED_BOOL)
		name := "true" if value else "false"
		id, create_error := entity_create(
			&scopes,
			Entity{name = name, kind = .Constant, scope = universe, state = .Resolved, type = types.TYPE_UNTYPED_BOOL, constant = constant},
		)
		_, insert_error := scope_insert(&scopes, universe, id)
		if !testing.expect(t, constant_error == nil && create_error == nil && insert_error == nil) { return }
	}
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	type_checker_init(&type_checker, &resolver, &collection, &store, []^File{nil, &file}, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)
	for declaration in collection.declarations {
		state, err := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		invalid := name == "Overflow" || name == "Bad" || name == "Missing" || name == "Wrong" || name == "Mismatch" || name == "Negative_Shift"
		testing.expectf(t, err == nil && (state == .Invalid) == invalid, "%s: %v %v", name, state, err)
	}
	testing.expect(t, len(type_checker.diagnostics) == 0 && len(resolver.diagnostics) == 0)
	program: Checked_Program
	expression_checker_publish(&checker, &program)
	program.files = []File{{}, file}
	for declaration in collection.declarations {
		entity := entity_get(&scopes, declaration.entity)
		if entity.kind == .Type_Name || declaration.value.node == 0 { continue }
		info, found := expression_info(&program, 1, declaration.value.node)
		testing.expectf(t, found && (info.state == .Checked || info.state == .Invalid), "%s", entity.name)
		if entity.state == .Invalid { continue }
		if entity.kind == .Variable { testing.expect(t, !types.is_untyped(&store, info.type)) }
		if entity.name == "next" {
			binary := syntax.node_payload(&ast, declaration.value.node, syntax.Binary_Expr)
			right := expression_info(&program, 1, binary.right)
			testing.expect(t, right.type == byte_type && right.constant != 0 && right.plan != 0)
			conversion := plan(&program, right.plan)^.(Conversion_Plan)
			testing.expect(t, conversion.target == byte_type && conversion.source != Operand(Expression_Ref{1, binary.right}))
		}
		if entity.name == "address" || entity.name == "restored" || entity.name == "reinterpreted" {
			conversion := plan(&program, info.plan)^.(Conversion_Plan)
			testing.expect(t, conversion.source != Operand(Expression_Ref{1, declaration.value.node}) && conversion.target == info.type)
		}
		if entity.name == "Count" ||
		   entity.name == "letter" ||
		   entity.name == "negative" ||
		   entity.name == "bits" ||
		   entity.name == "quotient" ||
		   entity.name == "remainder" ||
		   entity.name == "Flipped" ||
		   entity.name == "Complement_Untyped" {
			value := constant_pool_get(&pool, info.constant).value.(big.Int)
			actual, value_error := big.int_get_i64(&value)
			expected := i64(6)
			switch entity.name {
			case "letter":
				expected = 97
			case "negative":
				expected = -128
			case "bits":
				expected = 5
			case "quotient":
				expected = -2
			case "remainder":
				expected = 2
			case "Flipped":
				expected = 255
			case "Complement_Untyped":
				expected = -6
			}
			testing.expectf(t, value_error == .None && actual == expected, "%s: %d", entity.name, actual)
		}
		if entity.name == "same" { testing.expect(t, constant_pool_get(&pool, info.constant).value.(bool)) }
	}
	buffer := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, "Buffer"))
	testing.expect(t, types.get(&store, buffer.type).count == 6)
}
