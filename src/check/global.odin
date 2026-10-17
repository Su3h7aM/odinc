package check

import "base:runtime"
import "oc:syntax"
import "oc:types"

// Publishes package-level variables after procedures: one symbol and one Global record each. A constant initializer
// is kept as a constant; any other initializer is marked dynamic for startup code.
@(private = "package")
expression_checker_publish_globals :: proc(checker: ^Expression_Checker, program: ^Checked_Program) -> runtime.Allocator_Error {
	scopes := checker.type_checker.resolver.scopes
	clear(&checker.globals)
	for entity, id in scopes.entities {
		if entity.kind != .Variable || entity.state != .Resolved { continue }
		variable, is_variable := entity.data.(Variable_Data)
		if !is_variable || (variable.storage != .Global && variable.storage != .Thread_Local) { continue }
		_, alignment, layout_error := types.layout(checker.type_checker.store, entity.type)
		if layout_error != .None { continue }
		thread_local := variable.storage == .Thread_Local
		symbol := Symbol_Id(len(checker.symbols))
		append(
			&checker.symbols,
			Symbol {
				entity = Entity_Id(id),
				kind = .Global,
				name = entity.name,
				type = entity.type,
				linkage = .Strong,
				thread_local = thread_local,
				alignment = u32(alignment),
			},
		) or_return
		checker.entity_symbols[id] = symbol
		global := Global {
			entity       = Entity_Id(id),
			symbol       = symbol,
			type         = entity.type,
			alignment    = u32(alignment),
			thread_local = thread_local,
		}
		if variable.initializer.node != 0 {
			view := expression_file_view(checker, variable.initializer.file) or_return
			info := expression_stored_info(checker, view, variable.initializer.node)
			if info.mode == .Constant {
				global.initializer = info.constant
			} else {
				global.dynamic_initializer = true
			}
		}
		append(&checker.globals, global) or_return
	}
	program.global_list = checker.globals[:]
	return nil
}

@(private = "file")
expression_stored_info :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index) -> Expression_Info {
	rows := checker.views[view].nodes
	index := int(node - checker.views[view].first_node)
	return Expression_Info {
		type = rows.types[index],
		constant = rows.constants[index],
		mode = rows.modes[index],
		entity = rows.entities[index],
		plan = rows.plans[index],
		scope = rows.scopes[index],
		state = rows.states[index],
	}
}
