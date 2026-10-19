package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
subtype_conversions_project_values_and_addresses :: proc(t: ^testing.T) {
	arena: virtual.Arena
	if !testing.expect_value(t, virtual.arena_init_growing(&arena), nil) { return }
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.sized_integer(&store, 8, true)
	fields := [?]types.Type_Field{{name = "padding", type = integer}, {name = "value", type = integer}}
	container := types.intern(&store, types.Type{kind = .Struct, fields = fields[:]})
	for pointer in ([?]bool{false, true}) {
		source_type, target_type := container, integer
		if pointer {
			source_type = types.intern(&store, types.Type{kind = .Pointer, elem = container})
			target_type = types.intern(&store, types.Type{kind = .Pointer, elem = integer})
		}
		parameters := fixture_clone([]types.Type_Id{source_type}, allocator)
		results := fixture_clone([]types.Type_Id{target_type}, allocator)
		signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = parameters, results = results})
		ast: syntax.Ast
		syntax.ast_init(&ast, allocator)
		defer syntax.ast_destroy(&ast)
		source := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
		conversion := syntax.ast_add_node(&ast, .Call_Expr, 0, 1, syntax.Call_Expr{})
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
		program := expression_fixture(&ast, &store, allocator, body, signature, entities, facts, {2})
		path := fixture_clone([]check.Member_Step{{type = container, field_index = 1, indirect = pointer}}, allocator)
		program.plan_table = fixture_clone(
			[]check.Plan{{}, check.Conversion_Plan{kind = .Subtype, source = check.Expression_Ref{1, source}, target = target_type, path = path}},
			allocator,
		)
		module: ir.Module
		errors, err := lower_program(&program, &module)
		defer delete(errors)
		if !testing.expect_value(t, err, nil) { return }
		defer ir.module_destroy(&module)
		testing.expect_value(t, len(errors), 0)
	}
}
