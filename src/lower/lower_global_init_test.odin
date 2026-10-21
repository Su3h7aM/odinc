package lower

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

// A global pointer initialized with the address of a composite literal must point at storage that outlives startup.
// Lowering materializes a hidden backing global for the literal instead of keeping the init.globals stack slot whose
// address the previous code stored.
@(test)
global_address_of_literal_materializes_backing_global :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	store := types.init()
	defer types.destroy(&store)
	integer := types.intern(&store, types.Type{kind = .Integer, count = 8, signed = true})
	record := types.intern(&store, types.Type{kind = .Struct, fields = []types.Type_Field{{name = "x", type = integer}}})
	pointer := types.intern(&store, types.Type{kind = .Pointer, elem = record})
	ast: syntax.Ast
	syntax.ast_init(&ast, allocator)
	defer syntax.ast_destroy(&ast)
	literal := syntax.ast_add_node(&ast, .Comp_Lit, 0, 1, syntax.Comp_Lit{})
	address := syntax.ast_add_node(&ast, .Unary_Expr, 0, 1, syntax.Unary_Expr{op = {kind = .And}, expr = literal})
	nodes := check.Typed_Nodes {
		types     = fixture_clone([]types.Type_Id{record, pointer}, allocator),
		constants = fixture_clone([]check.Const_Id{0, 0}, allocator),
		modes     = fixture_clone([]check.Addressing_Mode{.Value, .Value}, allocator),
		entities  = fixture_clone([]check.Entity_Id{0, 0}, allocator),
		plans     = fixture_clone([]check.Plan_Id{1, 0}, allocator),
		scopes    = fixture_clone([]check.Scope_Id{0, 0}, allocator),
		states    = fixture_clone([]check.Node_State{.Checked, .Checked}, allocator),
	}
	program := check.Checked_Program {
		type_data             = &store,
		files                 = fixture_clone([]check.File{{}, {ast = &ast}}, allocator),
		entities              = fixture_clone([]check.Entity{{}, {kind = .Variable, type = pointer}}, allocator),
		typed_views           = fixture_clone([]check.Typed_View{{}, {file = 1, first_node = 1, nodes = nodes}}, allocator),
		symbol_table          = fixture_clone([]check.Symbol{{}, {entity = 1, kind = .Global, name = "P", type = pointer}}, allocator),
		entity_symbols        = fixture_clone([]check.Symbol_Id{0, 1}, allocator),
		procedure_list        = fixture_clone([]check.Checked_Procedure{}, allocator),
		global_list           = fixture_clone(
			[]check.Global{{entity = 1, symbol = 1, type = pointer, alignment = 8, initializer_node = {file = 1, node = address}, initializer_view = 1}},
			allocator,
		),
		global_initialization = fixture_clone([]check.Entity_Id{1}, allocator),
		plan_table            = fixture_clone([]check.Plan{{}, check.Aggregate_Plan{type = record}}, allocator),
	}
	module: ir.Module
	errors, err := lower_program(&program, &module, context.allocator)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	if !testing.expect_value(t, len(errors), 0) { return }
	if !testing.expect_value(t, len(module.globals), 3) { return }
	backing := module.globals[2]
	testing.expect(t, strings.has_prefix(backing.name, "__odinc_internal_global_address_"), "literal backing must be a hidden global")
	testing.expect_value(t, backing.size, u32(8))
	testing.expect_value(t, backing.align, u32(8))
	testing.expect(t, backing.mutable, "literal backing must be writable at startup")
	found_initializer := false
	stores_backing_address := false
	for function in module.functions {
		if function.name != GLOBAL_INITIALIZER_NAME { continue }
		found_initializer = true
		for index in 1 ..< len(function.nodes) {
			id := ir.Node_Id(index)
			if function.nodes.kind[id] != .Symbol_Addr { continue }
			if function.nodes.data[id].symbol == (ir.Symbol_Ref{space = .Global, index = 2}) { stores_backing_address = true }
		}
	}
	testing.expect(t, found_initializer, "dynamic globals require init.globals")
	testing.expect(t, stores_backing_address, "global must store its backing global's address, not a dead stack slot")
}
