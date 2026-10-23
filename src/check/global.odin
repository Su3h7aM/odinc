package check

import "base:runtime"
import "core:fmt"
import "core:mem"
import "oc:syntax"
import "oc:types"

// Publishes package-level variables after procedures: one symbol and one Global record each. A constant initializer
// is kept as a constant; any other initializer is kept as a node for startup code.
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
		name := symbol_name(checker, program, entity) or_return
		if scope := scope_get(scopes, entity.scope); scope != nil && (scope.kind == .Procedure || scope.kind == .Block) {
			name = fmt.aprintf("%s-%d", name, id, allocator = mem.dynamic_arena_allocator(&checker.arena))
		}
		linkage := symbol_linkage(checker, entity) or_return
		append(
			&checker.symbols,
			Symbol {
				entity = Entity_Id(id),
				kind = .Global,
				name = name,
				type = entity.type,
				linkage = linkage,
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
			view := variable.initializer_view
			if scope := scope_get(scopes, entity.scope); scope == nil || (scope.kind != .Procedure && scope.kind != .Block) {
				view = expression_file_view(checker, variable.initializer.file) or_return
			}
			info := expression_stored_info(checker, view, variable.initializer.node)
			if info.mode == .Constant {
				global.initializer = info.constant
			} else {
				global.initializer_node = variable.initializer
				global.initializer_view = view
			}
		}
		append(&checker.globals, global) or_return
	}
	ordered := make([]Global, len(checker.globals), mem.dynamic_arena_allocator(&checker.arena)) or_return
	count := 0
	for rank in 0 ..< len(checker.packages) {
		for package_value, package_id in checker.packages {
			if package_value.init_order != u32(rank) { continue }
			for global in checker.globals {
				if scopes.entities[global.entity].package_id == Package_Id(package_id) {
					ordered[count] = global
					count += 1
				}
			}
		}
	}
	clear(&checker.globals)
	for global in ordered[:count] { append(&checker.globals, global) or_return }
	program.global_list = checker.globals[:]
	program.global_initialization = global_initialization_order(checker, checker.globals[:], mem.dynamic_arena_allocator(&checker.arena)) or_return
	return expression_checker_publish_startup(checker, program)
}

@(private)
expression_stored_info :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index) -> Expression_Info {
	return typed_view_info(&checker.views[view], node)
}
