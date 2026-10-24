package lower

import "core:math/big"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// An untyped integer past the signed range keeps its low 64 bits in an unsigned use, as in
// core:math/big's `_private_int_dr_setup`: `DIGIT((1 << _DIGIT_BITS) - a.digit[0])`.
// Pinned against the official compiler, which prints 9223372036854775813 for `u64(5) - (1 << 63)`.
@(test)
untyped_constant_past_signed_range_keeps_low_bits :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {word}, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	operand := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	shifted := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	difference := syntax.ast_add_node(&ast, .Binary_Expr, 0, 1, syntax.Binary_Expr{left = operand, op = {kind = .Sub}, right = shifted})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {difference})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = word}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(operand) - 1] = {
		type   = word,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(shifted) - 1] = {
		type     = types.TYPE_UNTYPED_INTEGER,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	facts[int(difference) - 1] = {
		type  = word,
		mode  = .Value,
		state = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	past_signed := big.Int{}
	big.int_set_from_integer(&past_signed, u64(1) << 63, allocator = allocator)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = types.TYPE_UNTYPED_INTEGER, value = past_signed}}, allocator)
	// The checker interns default types during checking, before lowering builds its layout table.
	_ = types.default_type_of_untyped(&store, types.TYPE_UNTYPED_INTEGER)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], {u64(5)}, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, actual.value, u64(9223372036854775813))
}

// A constant operand kept as an untyped integer reaches a float use through the target type, as in `t *= f64(64)`.
@(test)
untyped_integer_constant_converts_to_float :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	word := types.intern(&store, types.Type{kind = .Float, count = 8})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {word}, results = {word}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	shifted := syntax.ast_add_node(&ast, .Basic_Lit, 0, 1, syntax.Basic_Lit{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {shifted})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = word}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(shifted) - 1] = {
		type     = word,
		constant = 1,
		mode     = .Constant,
		state    = .Checked,
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
	sixty_four := big.Int{}
	big.int_set_from_integer(&sixty_four, 64, allocator = allocator)
	program.constant_table = fixture_clone([]check.Constant{{}, {type = types.TYPE_UNTYPED_INTEGER, value = sixty_four}}, allocator)
	// The checker interns default types during checking, before lowering builds its layout table.
	_ = types.default_type_of_untyped(&store, types.TYPE_UNTYPED_INTEGER)
	module: ir.Module
	errors, _, err := lower_program(&program, &module)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	actual, run_error := ir.interp_run(&module, module.functions[0], {0}, 1000, context.allocator)
	testing.expect_value(t, run_error, nil)
	testing.expect_value(t, actual.outcome, ir.Interp_Outcome.Value)
	testing.expect_value(t, transmute(f64)actual.value, 64)
}
