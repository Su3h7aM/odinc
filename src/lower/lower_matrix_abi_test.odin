package lower

import "base:runtime"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
matrix_abi_type :: proc(store: ^types.Store, elem: types.Type_Id, rows, columns: i64, row_major := false) -> types.Type_Id {
	return types.intern(store, types.Type{kind = .Matrix, elem = elem, count = rows, upper_bound = columns, row_major = row_major})
}

// A procedure taking only a matrix must lower cleanly, whether the matrix
// arrives in registers or through memory.
@(private)
lower_matrix_parameter :: proc(t: ^testing.T, store: ^types.Store, allocator: runtime.Allocator, shape: types.Type_Id) {
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, params = {shape}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = shape}}, allocator)
	program := expression_fixture(&ast, store, allocator, body, signature, entities, nil, {2})
	module: ir.Module
	errors, err := lower_program(&program, &module, allocator)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
}

@(test)
matrix_parameters_bind_in_registers_and_through_memory :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	f32 := types.intern(&store, types.Type{kind = .Float, count = 4})
	i32 := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	shapes := []types.Type_Id {
		matrix_abi_type(&store, f32, 2, 2),
		matrix_abi_type(&store, f32, 2, 2, true),
		matrix_abi_type(&store, i32, 2, 2),
		matrix_abi_type(&store, f32, 1, 1),
		matrix_abi_type(&store, f32, 3, 3),
		matrix_abi_type(&store, f32, 4, 4),
	}
	for shape in shapes { lower_matrix_parameter(t, &store, allocator, shape) }
}

// An identity procedure returning its matrix parameter exercises the register
// and struct-return result paths.
@(private)
lower_matrix_identity :: proc(t: ^testing.T, store: ^types.Store, allocator: runtime.Allocator, shape: types.Type_Id) {
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, params = {shape}, results = {shape}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	operand := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	result := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {operand})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {result})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = shape}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(operand) - 1] = {
		type   = shape,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, {2})
	module: ir.Module
	errors, err := lower_program(&program, &module, allocator)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
}

@(test)
matrix_results_return_in_registers_and_through_struct_return :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	f32 := types.intern(&store, types.Type{kind = .Float, count = 4})
	lower_matrix_identity(t, &store, allocator, matrix_abi_type(&store, f32, 2, 2))
	lower_matrix_identity(t, &store, allocator, matrix_abi_type(&store, f32, 4, 4))
}
