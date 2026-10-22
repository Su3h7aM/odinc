package lower

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:sync"
import "core:thread"
import "oc:check"
import "oc:ir"

// Staged divergence: the official compiler lowers every procedure, we lower only what the roots reach
// (docs/archive/05-lower-design.md section 4). Roots are user-package procedures and globals and the startup
// procedures of the runtime requirements, plus the already-lowered generated startup procedures. Each round
// lowers the newly reached procedures in parallel,
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

// Lowering appends globals after the mark tables are sized, so the tables grow
// with the module before every use. Old slices stay in the scratch arena.
@(private)
grow_reach_marks :: proc(marks: ^Reach_Marks, count: int, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	if count <= len(marks.globals) { return nil }
	globals := make([]bool, count, allocator) or_return
	copy(globals, marks.globals)
	marks.globals = globals
	scanned := make([]bool, count, allocator) or_return
	copy(scanned, marks.global_scanned)
	marks.global_scanned = scanned
	return nil
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
	startup_roots: []u32,
	symbols: []ir.Symbol_Ref,
	worker_count: int,
	allocator: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (
	reached_globals: []bool,
	err: runtime.Allocator_Error,
) {
	marks := Reach_Marks {
		functions      = make([]bool, len(module.functions), scratch) or_return,
		lowered        = make([]bool, len(module.functions), scratch) or_return,
		globals        = make([]bool, len(module.globals), scratch) or_return,
		global_scanned = make([]bool, len(module.globals), scratch) or_return,
	}
	// The generated startup procedures are already lowered, so only their references need marking. Without
	// this, helpers used only by dynamic global initializers stay unreached and their calls trap.
	for root in startup_roots {
		assert(int(root) >= len(jobs) && int(root) < len(module.functions))
		scan_function_references(module.functions[root], &marks)
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

	pool_arena: virtual.Arena
	pool: thread.Pool
	pooled := worker_count > 1
	if pooled {
		virtual.arena_init_growing(&pool_arena) or_return
		thread.pool_init(&pool, virtual.arena_allocator(&pool_arena), worker_count)
		thread.pool_start(&pool)
	}
	defer if pooled {
		thread.pool_join(&pool)
		thread.pool_destroy(&pool)
		virtual.arena_destroy(&pool_arena)
	}
	done: sync.Sema
	for {
		grow_reach_marks(&marks, len(module.globals), scratch) or_return
		scan_reached_globals(module, &marks)
		pending := make([dynamic]^Procedure_Job, scratch) or_return
		for &job, index in jobs {
			if marks.functions[index] && !marks.lowered[index] {
				marks.lowered[index] = true
				append(&pending, &job) or_return
			}
		}
		if len(pending) == 0 { break }
		slice.stable_sort_by(pending[:], larger_procedure_first)
		for job in pending {
			job.function.allocator = virtual.arena_allocator(&job.function.arena)
		}
		if pooled {
			tasks := make([]Pool_Task, len(pending), scratch) or_return
			for job, index in pending {
				tasks[index] = Pool_Task {
					job  = job,
					done = &done,
				}
				thread.pool_add_task(&pool, job.function.allocator, run_pool_task, &tasks[index])
			}
			for _ in pending { sync.wait(&done) }
		} else {
			for job in pending { run_procedure_serially(job) }
		}
		grow_reach_marks(&marks, len(module.globals), scratch) or_return
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

@(private)
Pool_Task :: struct {
	job:  ^Procedure_Job,
	done: ^sync.Sema,
}

@(private)
run_pool_task :: proc(task: thread.Task) {
	pool_task := (^Pool_Task)(task.data)
	run_procedure(thread.Task{data = pool_task.job})
	sync.post(pool_task.done, 1)
}

@(private)
run_procedure_serially :: proc(job: ^Procedure_Job) {
	context.allocator = job.function.allocator
	run_procedure(thread.Task{data = job})
}

@(private)
procedure_source_length :: proc(job: ^Procedure_Job) -> i64 {
	return i64(job.procedure.source.end) - i64(job.procedure.source.start)
}

// Scheduling only: every job writes its own function, so the dispatch order does not change the output.
@(private)
larger_procedure_first :: proc(a, b: ^Procedure_Job) -> bool {
	return procedure_source_length(a) > procedure_source_length(b)
}
