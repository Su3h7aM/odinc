package lower

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "oc:check"
import "oc:ir"

// Only procedures reached from the entry point, explicit roots, globals and generated startup are lowered.
@(private)
Global_Scan :: enum u8 {
	Unscanned,
	Functions, // only the function references of an unreached global are needed
	All,
}

@(private)
Reach_Marks :: struct {
	functions:   []bool, // by function index
	lowered:     []bool, // by function index
	globals:     []bool, // by module global index
	global_scan: []Global_Scan, // by module global index
	externs:     []bool,
}

@(private)
is_user_entity :: proc(program: ^check.Checked_Program, entity: check.Entity_Id, library_prefixes: []string) -> bool {
	package_id := program.entities[entity].package_id
	if int(package_id) >= len(program.packages) { return true }
	package_value := program.packages[package_id]
	if package_value.kind != .User { return false }
	for prefix in library_prefixes {
		if strings.has_prefix(package_value.key, prefix) { return false }
	}
	return true
}

// Our native process entry replaces the runtime-provided CRT and no-CRT entries.
@(private)
is_runtime_entry :: proc(program: ^check.Checked_Program, entity: check.Entity) -> bool {
	return(
		int(entity.package_id) < len(program.packages) &&
		program.packages[entity.package_id].kind == .Runtime &&
		(entity.name == "main" || entity.name == "_start_odin") \
	)
}

@(private)
mark_symbol :: proc(marks: ^Reach_Marks, symbol: ir.Symbol_Ref) {
	switch symbol.space {
	case .Function:
		marks.functions[symbol.index] = true
	case .Global:
		marks.globals[symbol.index] = true
	case .Extern:
		if int(symbol.index) < len(marks.externs) { marks.externs[symbol.index] = true }
	case .None, .Local_Blob:
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
	scans := make([]Global_Scan, count, allocator) or_return
	copy(scans, marks.global_scan)
	marks.global_scan = scans
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

// Every global is emitted, so the functions an unreached global names are needed too. Its other relocations
// matter only once it is reached.
@(private)
scan_global_references :: proc(module: ^ir.Module, marks: ^Reach_Marks) {
	for global, index in module.globals {
		if marks.globals[index] {
			if marks.global_scan[index] == .All { continue }
			marks.global_scan[index] = .All
			for reloc in global.relocs { mark_symbol(marks, reloc.target) }
		} else if marks.global_scan[index] == .Unscanned {
			marks.global_scan[index] = .Functions
			for reloc in global.relocs {
				if reloc.target.space == .Function { mark_symbol(marks, reloc.target) }
			}
		}
	}
}

// The function is created when its procedure is first reached, so the module holds no function for any other.
@(private)
create_procedure_function :: proc(job: ^Procedure_Job, module: ^ir.Module, allocator: runtime.Allocator) -> runtime.Allocator_Error {
	function := ir.function_make(allocator, ir.Function_Id(job.function_index), job.name, 0) or_return
	function.linkage = job.linkage
	function.target_features = job.procedure.target_features
	function.disabled_target_features = job.procedure.disabled_target_features
	function.signature = ir.add_signature(function, job.abi_signature)
	if function.error != nil {
		ir.function_destroy(function)
		return function.error
	}
	module.functions[job.function_index] = function
	job.function = function
	return nil
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
	library_prefixes: []string,
	allocator: runtime.Allocator,
	scratch: runtime.Allocator,
) -> (
	reached_globals: []bool,
	reached_externs: []bool,
	err: runtime.Allocator_Error,
) {
	marks := Reach_Marks {
		functions   = make([]bool, len(module.functions), scratch) or_return,
		lowered     = make([]bool, len(module.functions), scratch) or_return,
		globals     = make([]bool, len(module.globals), scratch) or_return,
		global_scan = make([]Global_Scan, len(module.globals), scratch) or_return,
		externs     = make([]bool, len(module.externs), scratch) or_return,
	}
	// The generated startup procedures are already lowered, so only their references need marking. Without
	// this, helpers used only by dynamic global initializers stay unreached and their calls trap.
	for root in startup_roots {
		assert(int(root) >= len(jobs) && int(root) < len(module.functions))
		scan_function_references(module.functions[root], &marks)
	}
	for &job, index in jobs {
		entity := program.entities[job.procedure.entity]
		if int(entity.package_id) >= len(program.packages) { marks.functions[index] = true }
	}
	for global in check.globals(program) {
		if is_user_entity(program, global.entity, library_prefixes) { mark_symbol(&marks, symbols[global.symbol]) }
	}
	for symbol, index in check.symbols(program) {
		entity := program.entities[symbol.entity]
		required := .Required in entity.flags && !is_runtime_entry(program, entity)
		if .Export in entity.flags || required { mark_symbol(&marks, symbols[index + 1]) }
	}
	runtime_requirements := check.runtime_requirements(program)
	mark_entity(program, symbols, &marks, runtime_requirements.entry_point)
	mark_entity(program, symbols, &marks, runtime_requirements.init_context)
	for ordered in runtime_requirements.init_procedures { mark_entity(program, symbols, &marks, ordered.entity) }
	for ordered in runtime_requirements.fini_procedures { mark_entity(program, symbols, &marks, ordered.entity) }

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
		scan_global_references(module, &marks)
		pending := make([dynamic]^Procedure_Job, scratch) or_return
		for &job, index in jobs {
			if marks.functions[index] && !marks.lowered[index] {
				marks.lowered[index] = true
				append(&pending, &job) or_return
			}
		}
		if len(pending) == 0 { break }
		for job in pending {
			create_procedure_function(job, module, allocator) or_return
		}
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
	return marks.globals, marks.externs, nil
}

// Drops initializer errors of unreached runtime globals; user globals always report.
@(private)
prune_unreached_global_errors :: proc(
	program: ^check.Checked_Program,
	symbols: []ir.Symbol_Ref,
	reached_globals: []bool,
	library_prefixes: []string,
	errors: ^[dynamic]Lower_Error,
) -> runtime.Allocator_Error {
	kept := 0
	for error in errors {
		unreached :=
			error.feature == .Global_Initializer &&
			!is_user_entity(program, error.entity, library_prefixes) &&
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
