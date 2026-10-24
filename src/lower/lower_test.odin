package lower

import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
empty_procedure_verifies :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 2, syntax.Block_Stmt{})
	program := check.Checked_Program {
		type_data      = &store,
		files          = {{}, {ast = &ast}},
		symbol_table   = {{}, {entity = 1, kind = .Procedure, name = "empty", type = signature}},
		entities       = {{}, {name = "empty", kind = .Procedure, state = .Resolved, type = signature}},
		entity_symbols = {0, 1},
		procedure_list = {{entity = 1, symbol = 1, signature = signature, convention = .Contextless, body = {1, body}}},
	}
	module: ir.Module
	errors, _, err := lower_program(&program, &module, context.allocator, worker_count = 2)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
	if !testing.expect_value(t, len(module.functions), 1) { return }
	function := module.functions[0]
	testing.expect_value(t, function.name, "empty")
	testing.expect(t, function.stop != ir.NODE_NONE)
	verification_errors, verification_error := ir.verify(function, context.allocator, &module)
	defer delete(verification_errors)
	testing.expect_value(t, verification_error, nil)
	testing.expect_value(t, len(verification_errors), 0)
}

@(test)
checked_target_features_copied_to_ir :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	first_body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 2, syntax.Block_Stmt{})
	second_body := syntax.ast_add_node(&ast, .Block_Stmt, 2, 4, syntax.Block_Stmt{})
	program := check.Checked_Program {
		type_data      = &store,
		files          = {{}, {ast = &ast}},
		symbol_table   = {
			{},
			{entity = 1, kind = .Procedure, name = "plain", type = signature},
			{entity = 2, kind = .Procedure, name = "enabled", type = signature},
		},
		entities       = {
			{},
			{name = "plain", kind = .Procedure, state = .Resolved, type = signature},
			{name = "enabled", kind = .Procedure, state = .Resolved, type = signature},
		},
		entity_symbols = {0, 1, 2},
		procedure_list = {
			{
				entity = 1,
				symbol = 1,
				signature = signature,
				convention = .Contextless,
				body = {1, first_body},
				disabled_target_features = types.x86_disabled_features({.Avx}),
				microarch = .V2,
			},
			{entity = 2, symbol = 2, signature = signature, convention = .Contextless, body = {1, second_body}, target_features = {.Avx2}, microarch = .V2},
		},
		microarch      = .V2,
	}
	module: ir.Module
	errors, _, err := lower_program(&program, &module, context.allocator, worker_count = 2)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
	if !testing.expect_value(t, len(module.functions), 2) { return }
	testing.expect(t, module.functions[0].target_features == {})
	testing.expect(t, module.functions[0].disabled_target_features == types.x86_disabled_features({.Avx}))
	testing.expect(t, module.functions[1].target_features == types.X86_Features{.Avx2})
	testing.expect(t, module.functions[1].disabled_target_features == {})
	testing.expect_value(t, module.microarch, types.X86_Level.V2)
}

@(test)
local_uninitialized_declaration_skips_zero_initialization :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	program := check.Checked_Program {
		type_data = &store,
		entities  = {{}, {type = integer}, {type = integer}},
	}
	layouts := make([]Type_Layout, int(integer) + 1, context.allocator)
	layouts[integer] = {
		size  = 8,
		align = 8,
	}
	defer delete(layouts)
	function, make_error := ir.function_make(context.allocator, 0, "locals", 0)
	if !testing.expect_value(t, make_error, nil) { return }
	defer ir.function_destroy(function)
	function.signature = ir.add_signature(function, ir.Signature{})
	entry := ir.start(function)
	builder, builder_error := ir.builder_make(context.allocator, function, entry)
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
		address_taken = {false, false, false},
	}
	state.local_entities.allocator = context.allocator
	state.locals = make(map[check.Entity_Id]Local_Binding, context.allocator)
	defer delete(state.local_entities)
	defer delete(state.locals)
	bind_local(&state, 1, 0, false)
	bind_local(&state, 2, 0, true)
	if !testing.expect(t, !state.failed && job.function.error == nil) { return }
	uninitialized := ir.variable_get(builder, state.locals[1].variable)
	zeroed := ir.variable_get(builder, state.locals[2].variable)
	testing.expect_value(t, function.nodes.kind[uninitialized], ir.Node_Kind.Undef)
	testing.expect_value(t, function.nodes.kind[zeroed], ir.Node_Kind.Const_Int)
	testing.expect_value(t, function.nodes.data[zeroed].int_value, i64(0))
}
