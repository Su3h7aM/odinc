package lower

import "base:runtime"
import "core:mem"
import "core:thread"
import "oc:check"
import "oc:ir"

// Staged divergence: the official compiler lowers every procedure, we lower only what the roots reach
// (docs/05-lower-design.md section 4). Roots are user-package procedures and globals and the startup
// procedures of the runtime requirements. Each round lowers the newly reached procedures in parallel,
// then marks the symbols their code and data reference. An unreached procedure gets an `unreachable`
// body, so lowering errors in unused runtime code never fail the build.
@(private)
Reach_Marks :: struct {
	functions:      []bool, // by function index
	lowered:        []bool, // by function index
	globals:        []bool, // by module global index
	global_scanned: []bool, // by module global index
}

@(private)
is_user_entity :: proc(program: ^check.Checked_Program, entity: check.Entity_Id) -> bool {
	package_id := program.entities[entity].package_id
	return int(package_id) >= len(program.packages) || program.packages[package_id].kind == .User
}

@(private)
mark_symbol :: proc(marks: ^Reach_Marks, symbol: ir.Symbol_Ref) {
	switch symbol.space {
	case .Function:
		marks.functions[symbol.index] = true
	case .Global:
		marks.globals[symbol.index] = true
	case .None, .Extern, .Local_Blob:
	}
}

@(private)
mark_entity :: proc(program: ^check.Checked_Program, symbols: []ir.Symbol_Ref, marks: ^Reach_Marks, entity: check.Entity_Id) {
	if entity == 0 { return }
	mark_symbol(marks, symbols[check.entity_symbol(program, entity)])
}

@(private)
scan_function_references :: proc(function: ^ir.Function, marks: ^Reach_Marks) {
	for index in 1 ..< len(function.nodes) {
		if kind := function.nodes.kind[index]; kind == .Symbol_Addr || kind == .Tls_Addr {
			mark_symbol(marks, function.nodes.data[index].symbol)
		}
	}
	for blob in function.blobs {
		for reloc in blob.relocs { mark_symbol(marks, reloc.target) }
	}
}

@(private)
scan_reached_globals :: proc(module: ^ir.Module, marks: ^Reach_Marks) {
	for index in 0 ..< len(module.globals) {
		if !marks.globals[index] || marks.global_scanned[index] { continue }
		marks.global_scanned[index] = true
		for reloc in module.globals[index].relocs { mark_symbol(marks, reloc.target) }
	}
}

// An unreached body is never run, so it only needs to be valid IR for the backend.
@(private)
stub_unreached_procedure :: proc(function: ^ir.Function) -> ir.Error {
	function.signature = ir.add_signature(function, ir.Signature{})
	if function.error != nil { return function.error }
	entry := ir.start(function)
	ir.unreachable(function, entry.control, entry.memory)
	return ir.function_finish(function)
}

// Lowers the procedures reached from the roots and returns, per module global, whether it is reached.
@(private)
lower_reachable :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	jobs: []Procedure_Job,
	symbols: []ir.Symbol_Ref,
	worker_count: int,
	allocator: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (
	reached_globals: []bool,
	err: runtime.Allocator_Error,
) {
	marks := Reach_Marks {
		functions      = make([]bool, len(jobs), scratch) or_return,
		lowered        = make([]bool, len(jobs), scratch) or_return,
		globals        = make([]bool, len(module.globals), scratch) or_return,
		global_scanned = make([]bool, len(module.globals), scratch) or_return,
	}
	for &job, index in jobs {
		if is_user_entity(program, job.procedure.entity) { marks.functions[index] = true }
	}
	for global in check.globals(program) {
		if is_user_entity(program, global.entity) { mark_symbol(&marks, symbols[global.symbol]) }
	}
	runtime_requirements := check.runtime_requirements(program)
	mark_entity(program, symbols, &marks, runtime_requirements.entry_point)
	mark_entity(program, symbols, &marks, runtime_requirements.init_context)
	for ordered in runtime_requirements.init_procedures { mark_entity(program, symbols, &marks, ordered.entity) }
	for ordered in runtime_requirements.fini_procedures { mark_entity(program, symbols, &marks, ordered.entity) }
	for entity in runtime_requirements.tests { mark_entity(program, symbols, &marks, entity) }

	locked_allocator: mem.Mutex_Allocator
	mem.mutex_allocator_init(&locked_allocator, allocator)
	worker_allocator := mem.mutex_allocator(&locked_allocator)
	for {
		scan_reached_globals(module, &marks)
		pending := make([dynamic]^Procedure_Job, scratch) or_return
		for &job, index in jobs {
			if marks.functions[index] && !marks.lowered[index] {
				marks.lowered[index] = true
				append(&pending, &job) or_return
			}
		}
		if len(pending) == 0 { break }
		pool: thread.Pool
		thread.pool_init(&pool, worker_allocator, min(max(worker_count, 1), len(pending)))
		for job in pending {
			job.function.allocator = worker_allocator
			thread.pool_add_task(&pool, worker_allocator, run_procedure, job)
		}
		thread.pool_start(&pool)
		thread.pool_finish(&pool)
		thread.pool_destroy(&pool)
		for job in pending {
			job.function.allocator = allocator
			scan_function_references(job.function, &marks)
		}
	}

	for &job, index in jobs {
		if marks.lowered[index] { continue }
		clear(&job.errors)
		if stub_error := stub_unreached_procedure(job.function); stub_error != nil {
			if allocation_error, is_allocation := stub_error.(runtime.Allocator_Error); is_allocation { return nil, allocation_error }
			panic("unreached procedure stub failed verification")
		}
	}
	return marks.globals, nil
}

// Drops initializer errors of unreached runtime globals; user globals always report.
@(private)
prune_unreached_global_errors :: proc(
	program: ^check.Checked_Program,
	symbols: []ir.Symbol_Ref,
	reached_globals: []bool,
	errors: ^[dynamic]Lower_Error,
) -> runtime.Allocator_Error {
	kept := 0
	for error in errors {
		unreached :=
			error.feature == .Global_Initializer &&
			!is_user_entity(program, error.entity) &&
			!reached_globals[symbols[check.entity_symbol(program, error.entity)].index]
		if unreached { continue }
		errors[kept] = error
		kept += 1
	}
	return resize(errors, kept)
}
