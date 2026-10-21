package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
swizzle_nested_wide_indices_preserve_values :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	byte := types.intern(&store, types.Type{kind = .Integer, count = 1})
	for kind in ([]types.Kind{.Array, .Simd_Vector}) {
		count: i64 = 300 if kind == .Array else 64
		array := types.intern(&store, types.Type{kind = kind, elem = byte, count = count})
		wide := types.intern(&store, types.Type{kind = kind, elem = byte, count = 8})
		signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {byte}, results = {byte}})
		ast: syntax.Ast
		syntax.ast_init(&ast, allocator)
		defer syntax.ast_destroy(&ast)
		parameter := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		declaration := syntax.ast_add_node(&ast, .Value_Decl, 0, 1, syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {name})})
		destination := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		assignment := syntax.ast_add_node(
			&ast,
			.Assign_Stmt,
			0,
			1,
			syntax.Assign_Stmt{op = {kind = .Eq}, lhs = syntax.ast_add_list(&ast, {destination}), rhs = syntax.ast_add_list(&ast, {parameter})},
		)
		first := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		second := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		copy_name := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		copy_declaration := syntax.ast_add_node(
			&ast,
			.Value_Decl,
			0,
			1,
			syntax.Value_Decl{is_mutable = true, names = syntax.ast_add_list(&ast, {copy_name}), values = syntax.ast_add_list(&ast, {second})},
		)
		last := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		returned := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {last})})
		body := syntax.ast_add_node(
			&ast,
			.Block_Stmt,
			0,
			1,
			syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {declaration, assignment, copy_declaration, returned})},
		)
		entities := fixture_clone(
			[]check.Entity {
				{},
				{kind = .Procedure, type = signature},
				{kind = .Variable, type = byte},
				{kind = .Variable, type = array},
				{kind = .Variable, type = wide},
			},
			allocator,
		)
		facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
		facts[int(parameter) - 1] = {
			type   = byte,
			mode   = .Variable,
			entity = 2,
			state  = .Checked,
		}
		facts[int(name) - 1] = {
			type   = array,
			mode   = .Variable,
			entity = 3,
			state  = .Checked,
		}
		facts[int(destination) - 1] = {
			type  = byte,
			mode  = .Variable,
			plan  = 1,
			state = .Checked,
		}
		facts[int(assignment) - 1] = {
			plan  = 2,
			state = .Checked,
		}
		facts[int(first) - 1] = {
			type  = wide,
			mode  = .Value,
			plan  = 3,
			state = .Checked,
		}
		facts[int(second) - 1] = {
			type  = wide,
			mode  = .Value,
			plan  = 4,
			state = .Checked,
		}
		facts[int(copy_name) - 1] = {
			type   = wide,
			mode   = .Variable,
			entity = 4,
			state  = .Checked,
		}
		facts[int(last) - 1] = {
			type  = byte,
			mode  = .Value,
			plan  = 5,
			state = .Checked,
		}
		program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
		program.plan_table = fixture_clone(
			[]check.Plan {
				{},
				check.Swizzle_Plan{root = check.Entity_Id(3), indices = {count - 1}, count = 1},
				check.Assignment_Plan{destinations = {check.Expression_Ref{1, destination}}, values = {check.Expression_Ref{1, parameter}}},
				check.Swizzle_Plan{root = check.Entity_Id(3), indices = {0, 1, 2, 3, 4, 5, 6, count - 1}, count = 8},
				check.Swizzle_Plan{root = check.Expression_Ref{1, first}, indices = {7, 6, 5, 4, 3, 2, 1, 0}, count = 8},
				check.Swizzle_Plan{root = check.Entity_Id(4), indices = {0}, count = 1},
			},
			allocator,
		)
		module: ir.Module
		errors, err := lower_program(&program, &module)
		defer delete(errors)
		if !testing.expect_value(t, err, nil) { continue }
		defer ir.module_destroy(&module)
		if !testing.expect_value(t, len(errors), 0) { continue }
		actual, run_error := ir.interp_run(&module, module.functions[0], {173}, 10000, context.allocator)
		testing.expect_value(t, run_error, nil)
		testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
		testing.expect_value(t, actual.value, 173)
	}
}
