package lower

import "core:mem/virtual"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
caller_location_aggregate_parameter_lowers :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	small := types.intern(&store, types.Type{kind = .Integer, count = 1})
	word := types.intern(&store, types.Type{kind = .Integer, count = 8})
	raw := types.intern(&store, types.Type{kind = .Raw_Pointer, count = 8})
	text := types.intern(&store, types.Type{kind = .String})
	location := types.intern(
		&store,
		types.Type {
			kind = .Struct,
			name = "Source_Code_Location",
			fields = []types.Type_Field {
				{name = "file_path", type = text},
				{name = "line", type = integer},
				{name = "column", type = integer},
				{name = "procedure", type = text},
			},
		},
	)
	parameters := []types.Type_Id{raw, small, text, word, location}
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = parameters})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})
	entities := make([]check.Entity, len(parameters) + 2, allocator)
	entities[1] = {
		kind = .Procedure,
		type = signature,
	}
	parameter_ids := make([]check.Entity_Id, len(parameters), allocator)
	for type, index in parameters {
		entities[index + 2] = {
			kind = .Variable,
			type = type,
		}
		parameter_ids[index] = check.Entity_Id(index + 2)
	}
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, nil, parameter_ids)
	module: ir.Module
	errors, err := lower_program(&program, &module, allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(errors), 0)
	defer ir.module_destroy(&module)
}

@(test)
enum_parameter_lowers_as_its_backing_integer :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 4, signed = true})
	enum_type := types.intern(&store, types.Type{kind = .Enum, name = "Mode", backing = integer, count = 2, lower_bound = 0, upper_bound = 1})
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless, params = {enum_type}})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 1, syntax.Block_Stmt{})
	entities := fixture_clone([]check.Entity{{}, {kind = .Procedure, type = signature}, {kind = .Variable, type = enum_type}}, allocator)
	program := expression_fixture(&ast, &store, allocator, body, signature, entities, nil, {2})
	module: ir.Module
	errors, err := lower_program(&program, &module, allocator)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
}
