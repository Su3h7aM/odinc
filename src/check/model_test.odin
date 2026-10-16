package check

import "core:math/big"
import "core:testing"
import "oc:syntax"
import "oc:types"

@(test)
builtin_kind_uses_checked_identity :: proc(t: ^testing.T) {
	kinds := [3]Builtin_Kind{.Syscall, .None, .Syscall}
	program := Checked_Program {
		builtin_kinds = kinds[:],
	}
	testing.expect_value(t, builtin_kind(&program, 2), Builtin_Kind.Syscall)
	testing.expect_value(t, builtin_kind(&program, 1), Builtin_Kind.None)
	testing.expect_value(t, builtin_kind(&program, 0), Builtin_Kind.None)
	testing.expect_value(t, builtin_kind(&program, Builtin_Id(len(kinds))), Builtin_Kind.None)
	testing.expect_value(t, builtin_kind(&program, 0xffff_ffff), Builtin_Kind.None)
	testing.expect_value(t, builtin_kind(nil, 2), Builtin_Kind.None)
	zero: Checked_Program
	testing.expect_value(t, builtin_kind(&zero, 2), Builtin_Kind.None)
}

@(test)
checked_views_keep_instances_separate :: proc(t: ^testing.T) {
	ast: syntax.Ast
	syntax.ast_init(&ast)
	defer syntax.ast_destroy(&ast)
	node := syntax.ast_add_node(&ast, .Ident, 0, 1, syntax.Ident{})
	original := ast.nodes[node]
	type_data := types.init()
	defer types.destroy(&type_data)
	integer := types.intern(&type_data, types.Type{kind = .Integer, count = 8, signed = true})
	floating := types.intern(&type_data, types.Type{kind = .Float, count = 8})
	type_ids := [2]types.Type_Id{integer, floating}
	constant_ids := [2]Const_Id{1, 2}
	modes := [2]Addressing_Mode{.Constant, .Value}
	entity_ids := [2]Entity_Id{1, 2}
	plan_ids := [2]Plan_Id{1, 2}
	scope_ids := [2]Scope_Id{1, 2}
	states := [2]Node_State{.Checked, .Checked}
	views: [3]Typed_View
	for i in 0 ..< 2 {
		views[i + 1] = Typed_View {
			file = 1,
			instance = Instance_Id(i),
			first_node = node,
			nodes = Typed_Nodes {
				types = type_ids[i:i + 1],
				constants = constant_ids[i:i + 1],
				modes = modes[i:i + 1],
				entities = entity_ids[i:i + 1],
				plans = plan_ids[i:i + 1],
				scopes = scope_ids[i:i + 1],
				states = states[i:i + 1],
			},
		}
	}
	plans := [3]Plan{nil, Conversion_Plan{target = integer}, Context_Plan{scope = 2}}
	values := [3]Constant{{}, {type = integer, value = big.Int{}}, {type = floating, value = Float_Value{width = 64}}}
	symbol_table := [2]Symbol{{}, {entity = 1, name = "example", type = integer}}
	entity_symbols := [3]Symbol_Id{0, 1, 1}
	files := [2]File{{}, {ast = &ast, path = "example.odin"}}
	procedure_list := [1]Checked_Procedure{{entity = 1, symbol = 1, view = 1}}
	global_list := [1]Global{{entity = 2, symbol = 1}}
	program := Checked_Program {
		typed_views = views[:],
		plan_table = plans[:],
		constant_table = values[:],
		symbol_table = symbol_table[:],
		entity_symbols = entity_symbols[:],
		files = files[:],
		procedure_list = procedure_list[:],
		global_list = global_list[:],
		type_data = &type_data,
		runtime = {entry_point = 1},
	}
	first, first_ok := expression_info(&program, 1, node)
	second, second_ok := expression_info(&program, 2, node)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first, Expression_Info{integer, 1, .Constant, 1, 1, 1, .Checked})
	testing.expect_value(t, second, Expression_Info{floating, 2, .Value, 2, 2, 2, .Checked})
	testing.expect_value(t, ast.nodes[node], original)
	testing.expect_value(t, entity_symbol(&program, 1), entity_symbol(&program, 2))
	testing.expect_value(t, plan(&program, first.plan), &plans[1])
	testing.expect_value(t, constant(&program, second.constant), &values[2])
	testing.expect_value(t, &procedures(&program)[0], &procedure_list[0])
	testing.expect_value(t, &symbols(&program)[0], &symbol_table[1])
	testing.expect_value(t, &globals(&program)[0], &global_list[0])
	testing.expect_value(t, &constants(&program)[0], &values[1])
	testing.expect_value(t, &sources(&program)[0], &files[1])
	testing.expect_value(t, type_store(&program), &type_data)
	testing.expect_value(t, runtime_requirements(&program).entry_point, Entity_Id(1))
	invalid_requests := [][2]u32{{0, u32(node)}, {3, u32(node)}, {1, 0}, {1, u32(node) + 1}, {1, 0xffff_ffff}}
	for invalid in invalid_requests {
		info, ok := expression_info(&program, View_Id(invalid[0]), syntax.Node_Index(invalid[1]))
		testing.expect(t, !ok && info == Expression_Info{})
	}
	testing.expect(t, plan(&program, 0) == nil && constant(&program, 0) == nil)
	zero: Checked_Program
	_, ok := expression_info(&zero, 1, node)
	testing.expect(t, !ok && entity_symbol(&zero, 1) == 0)
	testing.expect(t, len(symbols(&zero)) == 0 && len(constants(&zero)) == 0 && len(sources(&zero)) == 0)
	testing.expect(t, plan(nil, 1) == nil && type_store(nil) == nil && runtime_requirements(nil) == nil)
}
