package lower

import "core:strings"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
unreached_runtime_body_errors_only_when_reached :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	raw := types.intern(&store, types.Type{kind = .Raw_Pointer})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	equal_signature := types.intern(
		&store,
		types.Type{kind = .Procedure, convention = .Contextless, params = []types.Type_Id{raw, raw}, results = []types.Type_Id{boolean}},
	)
	empty := types.intern(&store, types.Type{kind = .Struct})
	program := check.Checked_Program {
		type_data      = &store,
		packages       = {{}, {kind = .Runtime}},
		files          = {{}, {ast = &ast}},
		entities       = {{}, {name = "helper", kind = .Procedure, state = .Resolved, type = signature, package_id = 1, declaration = {file = 1}}},
		symbol_table   = {{}, {entity = 1, kind = .Procedure, name = "helper", type = signature}},
		entity_symbols = {0, 1},
		procedure_list = {{entity = 1, symbol = 1, signature = equal_signature, convention = .Contextless, generated = {kind = .Equality, type = empty}}},
	}

	unreached: ir.Module
	unreached_errors, _, unreached_err := lower_program(&program, &unreached, context.allocator)
	defer delete(unreached_errors)
	defer ir.module_destroy(&unreached)
	testing.expect_value(t, unreached_err, nil)
	testing.expect_value(t, len(unreached_errors), 0)

	program.runtime.init_procedures = {{entity = 1}}
	reached: ir.Module
	reached_errors, _, reached_err := lower_program(&program, &reached, context.allocator)
	defer delete(reached_errors)
	defer ir.module_destroy(&reached)
	testing.expect_value(t, reached_err, nil)
	testing.expect_value(t, len(reached_errors), 1)
}

// A library package (a .User package under a library prefix) lowers its procedures only when reached; its @(init)
// procedures stay roots.
@(test)
library_procedures_lower_only_when_reached :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	raw := types.intern(&store, types.Type{kind = .Raw_Pointer})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	equal_signature := types.intern(
		&store,
		types.Type{kind = .Procedure, convention = .Contextless, params = []types.Type_Id{raw, raw}, results = []types.Type_Id{boolean}},
	)
	empty := types.intern(&store, types.Type{kind = .Struct})
	program := check.Checked_Program {
		type_data      = &store,
		packages       = {{}, {kind = .User, key = "/root/core/lib"}},
		files          = {{}, {ast = &ast}},
		entities       = {{}, {name = "helper", kind = .Procedure, state = .Resolved, type = signature, package_id = 1, declaration = {file = 1}}},
		symbol_table   = {{}, {entity = 1, kind = .Procedure, name = "helper", type = signature}},
		entity_symbols = {0, 1},
		procedure_list = {{entity = 1, symbol = 1, signature = equal_signature, convention = .Contextless, generated = {kind = .Equality, type = empty}}},
	}

	library: ir.Module
	library_errors, _, library_err := lower_program(&program, &library, context.allocator, library_prefixes = []string{"/root/core/"})
	defer delete(library_errors)
	defer ir.module_destroy(&library)
	testing.expect_value(t, library_err, nil)
	testing.expect_value(t, len(library_errors), 0)
	testing.expect(t, library.functions[0] == nil, "a library procedure without a reaching root must have no function")

	user: ir.Module
	user_errors, _, user_err := lower_program(&program, &user, context.allocator)
	defer delete(user_errors)
	defer ir.module_destroy(&user)
	testing.expect_value(t, user_err, nil)
	testing.expect(t, user.functions[0] != nil, "a user package procedure is a root and must lower")

	program.runtime.init_procedures = {{entity = 1}}
	initialized: ir.Module
	initialized_errors, _, initialized_err := lower_program(&program, &initialized, context.allocator, library_prefixes = []string{"/root/core/"})
	defer delete(initialized_errors)
	defer ir.module_destroy(&initialized)
	testing.expect_value(t, initialized_err, nil)
	testing.expect(t, initialized.functions[0] != nil, "a library @(init) procedure is a root and must lower")
}

// An unreached library global is still emitted, so the procedure its address names must lower.
@(test)
unreached_library_global_keeps_its_function_reference :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = signature})
	raw := types.intern(&store, types.Type{kind = .Raw_Pointer})
	boolean := types.intern(&store, types.Type{kind = .Bool})
	equal_signature := types.intern(
		&store,
		types.Type{kind = .Procedure, convention = .Contextless, params = []types.Type_Id{raw, raw}, results = []types.Type_Id{boolean}},
	)
	empty := types.intern(&store, types.Type{kind = .Struct})
	program := check.Checked_Program {
		type_data      = &store,
		packages       = {{}, {kind = .User, key = "/root/core/lib"}},
		files          = {{}, {ast = &ast}},
		entities       = {
			{},
			{name = "helper", kind = .Procedure, state = .Resolved, type = signature, package_id = 1, declaration = {file = 1}},
			{name = "G", kind = .Variable, state = .Resolved, type = pointer, package_id = 1, declaration = {file = 1}},
		},
		symbol_table   = {{}, {entity = 1, kind = .Procedure, name = "helper", type = signature}, {entity = 2, kind = .Global, name = "G", type = pointer}},
		entity_symbols = {0, 1, 2},
		procedure_list = {{entity = 1, symbol = 1, signature = equal_signature, convention = .Contextless, generated = {kind = .Equality, type = empty}}},
		constant_table = {{}, {type = pointer, value = check.Address_Value{symbol = 1}}},
		global_list    = {{entity = 2, symbol = 2, type = pointer, alignment = 8, initializer = 1}},
	}

	module: ir.Module
	errors, _, err := lower_program(&program, &module, context.allocator, library_prefixes = []string{"/root/core/"})
	defer delete(errors)
	defer ir.module_destroy(&module)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(errors), 0)
	global_emitted := false
	for global in module.globals { global_emitted ||= global.name == "G" }
	testing.expect(t, global_emitted, "the unreached library global must still be emitted")
	testing.expect(t, module.functions[0] != nil, "a procedure named by an unreached global's address must lower")
}

@(test)
lowering_output_is_independent_of_worker_count :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 2, syntax.Block_Stmt{})
	names := [?]string{"p1", "p2", "p3", "p4"}
	entities := make([]check.Entity, len(names) + 1, context.temp_allocator)
	symbols := make([]check.Symbol, len(names) + 1, context.temp_allocator)
	entity_symbols := make([]check.Symbol_Id, len(names) + 1, context.temp_allocator)
	procedures := make([]check.Checked_Procedure, len(names), context.temp_allocator)
	for name, index in names {
		entity := check.Entity_Id(index + 1)
		entities[entity] = {
			name  = name,
			kind  = .Procedure,
			state = .Resolved,
			type  = signature,
		}
		symbols[entity] = {
			entity = entity,
			kind   = .Procedure,
			name   = name,
			type   = signature,
		}
		entity_symbols[entity] = check.Symbol_Id(entity)
		procedures[index] = {
			entity     = entity,
			symbol     = check.Symbol_Id(entity),
			signature  = signature,
			convention = .Contextless,
			body       = {1, body},
		}
	}
	program := check.Checked_Program {
		type_data      = &store,
		files          = {{}, {ast = &ast}},
		symbol_table   = symbols,
		entities       = entities,
		entity_symbols = entity_symbols,
		procedure_list = procedures,
	}

	serial, serial_ok := lowered_text(&program, 1)
	repeated, repeated_ok := lowered_text(&program, 1)
	parallel, parallel_ok := lowered_text(&program, 3)
	wide, wide_ok := lowered_text(&program, 8)
	testing.expect(t, serial_ok && repeated_ok && parallel_ok && wide_ok)
	testing.expect_value(t, repeated, serial)
	testing.expect_value(t, parallel, serial)
	testing.expect_value(t, wide, serial)
}

@(private = "file")
lowered_text :: proc(program: ^check.Checked_Program, worker_count: int) -> (text: string, passed: bool) {
	module: ir.Module
	defer ir.module_destroy(&module)
	errors, _, err := lower_program(program, &module, context.allocator, worker_count = worker_count)
	defer delete(errors)
	if err != nil || len(errors) != 0 { return }
	builder := strings.builder_make(context.temp_allocator)
	if ir.print_module(strings.to_writer(&builder), &module) != nil { return }
	return strings.to_string(builder), true
}
