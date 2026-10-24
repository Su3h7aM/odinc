package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
promoted_literal_fields_store_in_source_order :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	inner := types.intern(
		&store,
		types.Type{kind = .Struct, fields = []types.Type_Field{{name = "padding", type = integer}, {name = "value", type = integer}}},
	)
	outer := types.intern(&store, types.Type{kind = .Struct, fields = []types.Type_Field{{name = "padding", type = integer}, {name = "inner", type = inner}}})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {inner, integer}, results = {integer}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	parent := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	leaf := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	literal := syntax.ast_add_node(&ast, .Comp_Lit, 0, 1, syntax.Comp_Lit{})
	selected := syntax.ast_add_node(&ast, .Selector_Expr, 0, 1, syntax.Selector_Expr{expr = literal})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {selected})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone(
		[]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = inner}, {kind = .Variable, type = integer}},
		allocator,
	)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(parent) - 1] = {
		type   = inner,
		mode   = .Variable,
		entity = 2,
		state  = .Checked,
	}
	facts[int(leaf) - 1] = {
		type   = integer,
		mode   = .Variable,
		entity = 3,
		state  = .Checked,
	}
	facts[int(literal) - 1] = {
		type  = outer,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	facts[int(selected) - 1] = {
		type  = integer,
		mode  = .Value,
		plan  = 2,
		state = .Checked,
	}
	facts[int(result) - 1] = {
		state = .Checked,
	}
	path := fixture_clone([]check.Member_Step{{type = outer, field_index = 1}, {type = inner, field_index = 1}}, allocator)
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2, 3})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Aggregate_Plan {
				type = outer,
				values = fixture_clone([]check.Operand{check.Expression_Ref{1, parent}, check.Expression_Ref{1, leaf}}, allocator),
				field_indices = fixture_clone([]u32{1, 1}, allocator),
				field_paths = fixture_clone([][]check.Member_Step{nil, path}, allocator),
			},
			check.Place_Plan{root = check.Expression_Ref{1, literal}, path = path},
		},
		allocator,
	)
	for reverse in ([2]bool{false, true}) {
		if reverse {
			plan := &program.plan_table[1].(check.Aggregate_Plan)
			plan.values[0], plan.values[1] = plan.values[1], plan.values[0]
			plan.field_paths[0], plan.field_paths[1] = plan.field_paths[1], plan.field_paths[0]
		}
		module: ir.Module
		errors, _, err := lower_program(&program, &module)
		defer delete(errors)
		defer ir.module_destroy(&module)
		if !testing.expect_value(t, err, nil) || !testing.expect_value(t, len(errors), 0) { return }
		actual, run_error := ir.interp_run(&module, module.functions[0], {11, 17, 23}, 1000, context.allocator)
		defer delete(actual.output)
		testing.expect_value(t, run_error, nil)
		testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
		testing.expect_value(t, actual.value, u64(17 if reverse else 23))
	}
}
