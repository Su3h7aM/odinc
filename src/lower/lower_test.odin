package lower

import "core:testing"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(test)
empty_procedure_verifies :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	signature := types.intern(&store, types.Type{kind = .Procedure, convention = .Contextless})
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	body := syntax.ast_add_node(&ast, .Block_Stmt, 0, 2, syntax.Block_Stmt{})
	program := check.Checked_Program {
		type_data      = &store,
		files          = {{}, {ast = &ast}},
		symbol_table   = {{}, {entity = 1, kind = .Procedure, name = "empty", type = signature}},
		entities       = {{}, {name = "empty", kind = .Procedure, state = .Resolved, type = signature}},
		entity_symbols = {0, 1},
		procedure_list = {{entity = 1, symbol = 1, signature = signature, convention = .Contextless, body = {1, body}}},
	}
	module: ir.Module
	errors, err := lower_program(&program, &module, context.allocator, worker_count = 2)
	defer delete(errors)
	if !testing.expect_value(t, err, nil) { return }
	defer ir.module_destroy(&module)
	testing.expect_value(t, len(errors), 0)
	if !testing.expect_value(t, len(module.functions), 1) { return }
	function := module.functions[0]
	testing.expect_value(t, function.name, "empty")
	testing.expect(t, function.stop != ir.NODE_NONE)
	verification_errors, verification_error := ir.verify(function, context.allocator, &module)
	defer delete(verification_errors)
	testing.expect_value(t, verification_error, nil)
	testing.expect_value(t, len(verification_errors), 0)
}
