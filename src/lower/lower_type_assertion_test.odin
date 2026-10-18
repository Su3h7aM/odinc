package lower

import "base:runtime"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
assertion_source_lowers :: proc(
	t: ^testing.T,
	allocator: runtime.Allocator,
	store: ^types.Store,
	source_type, target_type: types.Type_Id,
	variant: int,
	needs_typeid: bool,
	comma_ok := false,
) {
	parameters, params_error := make([]types.Type_Id, 1, allocator)
	if !testing.expect_value(t, params_error, nil) { return }
	parameters[0] = source_type
	results, results_error := make([]types.Type_Id, 1, allocator)
	if !testing.expect_value(t, results_error, nil) { return }
	results[0] = target_type
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, params = parameters, results = results})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	subject := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	assertion := syntax.ast_add_node(&ast, .Type_Assertion, 0, 1, syntax.Type_Assertion{expr = subject, type = target})
	returned := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {assertion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {returned})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = source_type}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(subject) - 1] = {
		type   = source_type,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(assertion) - 1] = {
		type  = target_type,
		mode  = .Optional_Ok,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Type_Assertion_Plan {
				source = check.Expression_Ref{1, subject},
				source_type = source_type,
				target_type = target_type,
				variant = variant,
				comma_ok = comma_ok,
			},
		},
		allocator,
	)
	if needs_typeid {
		program.runtime.type_info = fixture_clone([]check.Type_Info_Entry{{type = target_type, runtime_id = 1}}, allocator)
		boolean := types.intern(store, types.Type{kind = .Bool})
		u64_type := types.intern(store, types.Type{kind = .Integer, count = 8})
		integer_fields, integer_fields_error := make([]types.Type_Field, 1, allocator)
		if !testing.expect_value(t, integer_fields_error, nil) { return }
		integer_fields[0] = {
			name = "signed",
			type = boolean,
		}
		integer_info := types.intern(store, types.Type{kind = .Struct, name = "Type_Info_Integer", fields = integer_fields})
		variants, variants_error := make([]types.Type_Id, 1, allocator)
		if !testing.expect_value(t, variants_error, nil) { return }
		variants[0] = integer_info
		variant := types.intern(store, types.Type{kind = .Union, variants = variants})
		info_fields, info_fields_error := make([]types.Type_Field, 4, allocator)
		if !testing.expect_value(t, info_fields_error, nil) { return }
		info_fields[0] = {
			name = "size",
			type = u64_type,
		}
		info_fields[1] = {
			name = "align",
			type = u64_type,
		}
		info_fields[2] = {
			name = "id",
			type = u64_type,
		}
		info_fields[3] = {
			name = "variant",
			type = variant,
		}
		info := types.intern(store, types.Type{kind = .Struct, name = "Type_Info", fields = info_fields})
		program.runtime.type_info_type = info
		table_pointer := types.intern(store, types.Type{kind = .Pointer, elem = info})
		table_slice := types.intern(store, types.Type{kind = .Slice, elem = table_pointer})
		program.symbol_table = fixture_clone(
			[]check.Symbol {
				{},
				program.symbol_table[1],
				{kind = .Global, name = "runtime.type_table", type = table_slice},
				{kind = .Global, name = "__odinc_internal_type_info_entry_1", type = target_type},
			},
			allocator,
		)
	}
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expectf(t, len(errors) == 0, "source %d, typeid %v: %v", source_type, needs_typeid, errors)
	for function in module.functions {
		for id in 0 ..< len(function.nodes) {
			type := function.nodes.type[id]
			if function.nodes.kind[id] == .Const_Int && (type == .F16 || is_float_type(type)) {
				testing.expectf(t, false, "integer constant %d lowered with float type", id)
			}
		}
	}
}

@(test)
union_type_assertion_lowers_with_a_failure_trap :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	union_type := types.intern(&store, types.Type{kind = .Union, variants = {integer, boolean}})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {union_type}, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	subject := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	assertion := syntax.ast_add_node(&ast, .Type_Assertion, 0, 1, syntax.Type_Assertion{expr = subject, type = target})
	returned := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {assertion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {returned})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = union_type}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(subject) - 1] = {
		type   = union_type,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(assertion) - 1] = {
		type  = integer,
		mode  = .Optional_Ok,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Type_Assertion_Plan{source = check.Expression_Ref{1, subject}, source_type = union_type, target_type = integer, variant = 0}},
		allocator,
	)
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
}

@(test)
any_and_pointer_union_type_assertions_lower :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	union_type := types.intern(&store, types.Type{kind = .Union, variants = {integer, boolean}})
	pointer_type := types.intern(&store, types.Type{kind = .Pointer, elem = union_type})
	any_type := types.intern(&store, types.Type{kind = .Any})
	assertion_source_lowers(t, allocator, &store, pointer_type, integer, 0, false)
	assertion_source_lowers(t, allocator, &store, any_type, integer, -1, true)
	assertion_source_lowers(t, allocator, &store, union_type, integer, 0, false, true)
	assertion_source_lowers(t, allocator, &store, any_type, integer, -1, true, true)
}

@(test)
float_payload_comma_ok_zero_is_a_float_constant :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	float_type := types.intern(&store, types.Type{kind = .Float, count = 8})
	union_type := types.intern(&store, types.Type{kind = .Union, variants = {integer, float_type}})
	assertion_source_lowers(t, allocator, &store, union_type, float_type, 1, false, true)
}
