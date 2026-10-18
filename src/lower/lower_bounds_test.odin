package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// An `i32` low bound is widened to `int` before the slice header is built.
@(test)
slice_expression_widens_narrow_bounds :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	narrow := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	array := types.intern(&store, types.Type{kind = .Array, elem = integer, count = 4})
	slice := types.intern(&store, types.Type{kind = .Slice, elem = integer})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {array}, results = {slice}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	subject := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	low := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	slicing := syntax.ast_add_node(&ast, .Slice_Expr, 0, 1, syntax.Slice_Expr{expr = subject, low = low})
	returned := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {slicing})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {returned})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = array}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(subject) - 1] = {
		type   = array,
		entity = 2,
		mode   = .Variable,
		state  = .Checked,
	}
	facts[int(low) - 1] = {
		type     = narrow,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(slicing) - 1] = {
		type  = slice,
		plan  = 1,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan {
			{},
			check.Bounds_Plan{kind = .Slice, policy = .Disabled, operands = fixture_clone([]check.Operand{nil, check.Const_Id(1), nil}, allocator)},
		},
		allocator,
	)
	one: big.Int
	big.int_set_from_integer(&one, i64(1), allocator = allocator)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = narrow, value = one}}, allocator)
	module: ir.Module
	errors, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
}
