package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
map_index_assignment_results_lower :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	map_type := types.intern(&store, types.Type{kind = .Map, index = integer, elem = integer})
	rawptr := types.intern(&store, types.Type{kind = .Raw_Pointer})
	seed_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {map_type}, results = {integer}})
	get_signature := types.intern(
		&store,
		types.Type{kind = .Procedure, convention = .Contextless, params = {rawptr, rawptr, integer, rawptr}, results = {rawptr}},
	)
	hash_signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {rawptr, integer}, results = {integer}})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {map_type, integer, integer, boolean}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	map_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	key := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	index := syntax.ast_add_node(&ast, .Index_Expr, 0, 1, syntax.Index_Expr{expr = map_name, index = key})
	value_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	ok_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	assignment := syntax.ast_add_node(
		&ast,
		.Assign_Stmt,
		0,
		1,
		syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {value_name, ok_name}), rhs = syntax.ast_add_list(&ast, {index})},
	)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {assignment})})
	entities := fixture_clone(
		[]check.Entity {
			{},
			{kind = .Procedure, type = signature},
			{kind = .Variable, type = map_type},
			{kind = .Variable, type = integer},
			{kind = .Variable, type = integer},
			{kind = .Variable, type = boolean},
			{kind = .Procedure, name = "map_seed", type = seed_signature},
			{kind = .Procedure, name = "__dynamic_map_get", type = get_signature},
		},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(map_name) - 1] = {
		type   = map_type,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(key) - 1] = {
		type   = integer,
		mode   = .Value,
		entity = 3,
		state  = .Checked,
	}
	facts[int(index) - 1] = {
		type  = integer,
		mode  = .Map_Index,
		plan  = 1,
		state = .Checked,
	}
	facts[int(value_name) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 4,
		state  = .Checked,
	}
	facts[int(ok_name) - 1] = {
		type   = boolean,
		mode   = .Variable,
		entity = 5,
		state  = .Checked,
	}
	facts[int(assignment) - 1] = {
		plan  = 2,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2, 3, 4, 5})
	program.symbol_table = fixture_clone(
		[]check.Symbol {
			{},
			{entity = 1, kind = .Procedure, name = "multi", type = signature},
			{entity = 6, kind = .Extern, name = "map_seed", type = seed_signature},
			{entity = 7, kind = .Extern, name = "__dynamic_map_get", type = get_signature},
			{kind = .Global, name = "map_info", type = integer, alignment = 8},
			{kind = .Extern, name = "map_hasher", type = hash_signature},
			{kind = .Extern, name = "map_equal", type = hash_signature},
			{kind = .Extern, name = "key_cell", type = integer},
			{kind = .Extern, name = "value_cell", type = integer},
		},
		allocator,
	)
	program.entity_symbols[1], program.entity_symbols[6], program.entity_symbols[7] = 1, 2, 3
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Map_Index_Plan{map_value = check.Expression_Ref{1, map_name}, key = check.Expression_Ref{1, key}, comma_ok = true},
			check.Assignment_Plan {
				destinations = {{view = 1, node = value_name}, {view = 1, node = ok_name}},
				values = {
					check.Projection{expression = {view = 1, node = index}, index = 0},
					check.Projection{expression = {view = 1, node = index}, index = 1},
				},
				conversions = {0, 0},
			},
		},
		allocator,
	)
	runtime_helpers: [check.Runtime_Helper]check.Entity_Id
	runtime_helpers[.Map_Seed] = 6
	runtime_helpers[.Dynamic_Map_Get] = 7
	program.runtime = check.Runtime_Requirements {
		helpers  = runtime_helpers,
		map_info = {{type = map_type, key_cell = 7, value_cell = 8, key_hasher = 5, key_equal = 6, symbol = 4}},
	}
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expectf(t, len(errors) == 0, "map index assignment: %v", errors)
}

@(test)
type_assertion_address_names_payload :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	union_type := types.intern(&store, types.Type{kind = .Union, variants = {integer, boolean}})
	program := check.Checked_Program {
		type_data = &store,
		entities  = {{}, {kind = .Variable, type = union_type}},
	}
	layouts, layouts_error := prepare_layouts(&store, allocator)
	if !testing.expect_value(t, layouts_error, nil) { return }
	function, make_error := ir.function_make(allocator, 0, "assertion_address", 0)
	if !testing.expect_value(t, make_error, nil) { return }
	defer ir.function_destroy(function)
	ir.add_signature(function, ir.Signature{})
	entry := ir.start(function)
	builder, builder_error := ir.builder_make(allocator, function, entry)
	if !testing.expect_value(t, builder_error, nil) { return }
	defer ir.builder_destroy(builder)
	job := Procedure_Job {
		program  = &program,
		function = function,
		layouts  = layouts,
	}
	state := Procedure_State {
		job           = &job,
		builder       = builder,
		entry_control = entry.control,
	}
	state.local_entities.allocator = allocator
	state.locals = make(map[check.Entity_Id]Local_Binding, allocator)
	address := ir.stack_slot(function, entry.control, 16, 8)
	bind_local_address(&state, 1, address)
	plan := check.Type_Assertion_Plan {
		source      = check.Entity_Id(1),
		source_type = union_type,
		target_type = integer,
		variant     = 0,
	}
	payload := lower_type_assertion_address(&state, 0, plan)
	if !testing.expect(t, !state.failed && job.function.error == nil) { return }
	testing.expect_value(t, payload, address)
}
