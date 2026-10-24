package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
any_declaration_lowers_boxed_initial_value :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boxed_type := types.intern(&store, types.Type{kind = .Any})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	operand := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	declaration := syntax.ast_add_node(
		&ast,
		.Value_Decl,
		0,
		1,
		syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {name}), values = syntax.ast_add_list(&ast, {operand})},
	)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration})})
	entities := fixture_clone(
		[]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}, {kind = .Variable, type = boxed_type}},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(operand) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(name) - 1] = {
		type   = boxed_type,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(declaration) - 1] = {
		state = .Checked,
		plan  = 1,
	}
	facts[int(body) - 1] = {
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Assignment_Plan {
				destinations = fixture_clone([]check.Operand{check.Entity_Id(0)}, allocator),
				values = fixture_clone([]check.Operand{check.Expression_Ref{view = 1, node = operand}}, allocator),
				conversions = fixture_clone([]check.Plan_Id{2}, allocator),
			},
			check.Conversion_Plan{kind = .Box, source = check.Operand(check.Expression_Ref{view = 1, node = operand}), target = boxed_type},
		},
		allocator,
	)
	program.runtime.type_info = fixture_clone([]check.Type_Info_Entry{{type = integer, runtime_id = 7}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	testing.expect_value(t, err, nil)
	// The only error is the missing runtime Type_Info struct, which this fixture omits; boxing itself reports nothing.
	if !testing.expect_value(t, len(errors), 1) { return }
	testing.expect_value(t, errors[0].feature, Lower_Feature.Runtime_Type_Info)
	if !testing.expect_value(t, len(module.functions), 1) { return }
	verification_errors, verification_error := ir.verify(module.functions[0], context.allocator, &module)
	defer delete(verification_errors)
	testing.expect_value(t, verification_error, nil)
}

@(test)
any_field_initializer_lowers_boxed_value :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boxed_type := types.intern(&store, types.Type{kind = .Any})
	holder := types.intern(&store, types.Type{kind = .Struct, name = "Holder", fields = []types.Type_Field{{name = "value", type = boxed_type}}})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	operand := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	literal := syntax.ast_add_node(&ast, .Comp_Lit, 0, 1, syntax.Comp_Lit{elems = syntax.ast_add_list(&ast, {operand})})
	statement := syntax.ast_add_node(&ast, .Expr_Stmt, 0, 1, syntax.Expr_Stmt{expr = literal})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {statement})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(operand) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(literal) - 1] = {
		type  = holder,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(statement) - 1] = {
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Aggregate_Plan {
				type = holder,
				values = fixture_clone([]check.Operand{check.Expression_Ref{view = 1, node = operand}}, allocator),
				field_indices = fixture_clone([]u32{0}, allocator),
				conversions = fixture_clone([]check.Plan_Id{2}, allocator),
			},
			check.Conversion_Plan{kind = .Box, source = check.Operand(check.Expression_Ref{view = 1, node = operand}), target = boxed_type},
		},
		allocator,
	)
	program.runtime.type_info = fixture_clone([]check.Type_Info_Entry{{type = integer, runtime_id = 7}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	testing.expect_value(t, err, nil)
	if !testing.expect_value(t, len(errors), 1) { return }
	testing.expect_value(t, errors[0].feature, Lower_Feature.Runtime_Type_Info)
	if !testing.expect_value(t, len(module.functions), 1) { return }
	verification_errors, verification_error := ir.verify(module.functions[0], context.allocator, &module)
	defer delete(verification_errors)
	testing.expect_value(t, verification_error, nil)
}

@(test)
any_return_lowers_boxed_result :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boxed_type := types.intern(&store, types.Type{kind = .Any})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}, results = {boxed_type}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	operand := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {operand})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(operand) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(result) - 1] = {
		state = .Checked,
		plan  = 1,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Exit_Plan {
				kind = .Return,
				values = fixture_clone([]check.Operand{check.Expression_Ref{view = 1, node = operand}}, allocator),
				conversions = fixture_clone([]check.Plan_Id{2}, allocator),
			},
			check.Conversion_Plan{kind = .Box, source = check.Operand(check.Expression_Ref{view = 1, node = operand}), target = boxed_type},
		},
		allocator,
	)
	program.runtime.type_info = fixture_clone([]check.Type_Info_Entry{{type = integer, runtime_id = 7}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	testing.expect_value(t, err, nil)
	if !testing.expect_value(t, len(errors), 1) { return }
	testing.expect_value(t, errors[0].feature, Lower_Feature.Runtime_Type_Info)
	if !testing.expect_value(t, len(module.functions), 1) { return }
	verification_errors, verification_error := ir.verify(module.functions[0], context.allocator, &module)
	defer delete(verification_errors)
	testing.expect_value(t, verification_error, nil)
}

@(test)
any_boxing_lowers_value_and_typeid :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	boxed_type := types.intern(&store, types.Type{kind = .Any})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {integer}, results = {boxed_type}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	operand := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	boxed := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {boxed})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = integer}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(operand) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(boxed) - 1] = {
		type  = boxed_type,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(result) - 1] = {
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Box, source = check.Operand(check.Expression_Ref{view = 1, node = operand}), target = boxed_type}},
		allocator,
	)
	program.runtime.type_info = fixture_clone([]check.Type_Info_Entry{{type = integer, runtime_id = 7}}, allocator)

	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	defer ir.module_destroy(&module)
	testing.expect_value(t, err, nil)
	// The only error is the missing runtime Type_Info struct, which this fixture omits; boxing itself reports nothing.
	if !testing.expect_value(t, len(errors), 1) { return }
	testing.expect_value(t, errors[0].feature, Lower_Feature.Runtime_Type_Info)
	if !testing.expect_value(t, len(module.functions), 1) { return }
	verification_errors, verification_error := ir.verify(module.functions[0], context.allocator, &module)
	defer delete(verification_errors)
	testing.expect_value(t, verification_error, nil)
}
