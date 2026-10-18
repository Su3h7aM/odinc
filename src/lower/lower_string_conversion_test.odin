package lower

import "base:runtime"
import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
string_conversion_lowers :: proc(t: ^testing.T, allocator: runtime.Allocator, store: ^types.Store, source_type, target_type: types.Type_Id) {
	parameters := make([]types.Type_Id, 1, allocator)
	results := make([]types.Type_Id, 1, allocator)
	parameters[0], results[0] = source_type, target_type
	signature := types.intern(store, types.Type{kind = .Procedure, convention = .Contextless, params = parameters, results = results})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	source := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	target := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{expr = target, args = syntax.ast_add_list(&ast, {source})})
	returned := syntax.ast_add_node(&ast, .Return_Stmt, 0, 1, syntax.Return_Stmt{results = syntax.ast_add_list(&ast, {conversion})})
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{stmts = syntax.ast_add_list(&ast, {returned})})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = source_type}}, allocator)
	facts := make([]check.Expression_Info, len(ast.nodes) - 1, allocator)
	facts[int(source) - 1] = {
		type   = source_type,
		mode   = .Value,
		entity = 2,
		state  = .Checked,
	}
	facts[int(conversion) - 1] = {
		type  = target_type,
		mode  = .Value,
		plan  = 1,
		state = .Checked,
	}
	program := expression_fixture(&ast, store, allocator, body, signature, entities, facts, {2})
	program.plan_table = fixture_clone(
		[]check.Plan{{}, check.Conversion_Plan{kind = .Cast, source = check.Expression_Ref{1, source}, target = target_type}},
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
cstring_and_cstring16_conversions_lower_to_scans :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	cstring := types.intern(&store, types.Type{kind = .CString})
	string := types.intern(&store, types.Type{kind = .String})
	cstring16 := types.intern(&store, types.Type{kind = .CString16})
	string16 := types.intern(&store, types.Type{kind = .String16})
	string_conversion_lowers(t, allocator, &store, cstring, string)
	string_conversion_lowers(t, allocator, &store, cstring16, string16)
}
