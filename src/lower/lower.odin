package lower

import "base:runtime"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:types"

@(private)
Procedure_Job :: struct {
	program:          ^check.Checked_Program,
	module:           ^ir.Module,
	procedure:        check.Checked_Procedure,
	function:         ^ir.Function,
	symbols:          []ir.Symbol_Ref,
	default_context:  ir.Symbol_Ref,
	parameters:       []types.Abi_Param,
	layouts:          []Type_Layout,
	declarations:     []Procedure_Declaration,
	abi_plans:        ^Abi_Plans,
	address_taken:    []bool,
	extern_base:      u32,
	extern_names:     [dynamic]string,
	errors:           [dynamic]Lower_Error,
	allocation_error: runtime.Allocator_Error,
}

// Stand-in for runtime.Context until base/runtime compiles: a zeroed block, so no allocator or logger is set.
DEFAULT_CONTEXT_NAME :: "runtime.context"
DEFAULT_CONTEXT_SIZE :: 256

// Initializes module in place; do not move it. The caller destroys it with ir.module_destroy
// and deletes errors with allocator. Allocation failure destroys the partial module.
// A nonempty error list means the module must not be used for code generation.
lower_program :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	allocator := context.allocator,
	worker_count := 1,
) -> (
	errors: []Lower_Error,
	err: runtime.Allocator_Error,
) {
	assert(program != nil && module != nil && check.type_store(program) != nil)
	assert(len(module.functions) == 0 && len(module.globals) == 0 && len(module.externs) == 0)
	ir.module_init(module) or_return
	defer if err != nil {
		ir.module_destroy(module)
		delete(errors, allocator)
		errors = nil
	}
	module.microarch = program.microarch
	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch) or_return
	defer virtual.arena_destroy(&scratch)
	scratch_allocator := virtual.arena_allocator(&scratch)
	collected := make([dynamic]Lower_Error, scratch_allocator) or_return
	symbols := declare_symbols(program, module, allocator) or_return
	fill_globals(program, module, symbols, &collected) or_return
	default_context := ir.Symbol_Ref {
		space = .Global,
		index = u32(len(module.globals)),
	}
	append(&module.globals, ir.Global{name = DEFAULT_CONTEXT_NAME, size = DEFAULT_CONTEXT_SIZE, align = 16, mutable = true}) or_return
	runtime_requirements := check.runtime_requirements(program)
	fill_type_info(program, module, symbols, &collected) or_return
	fill_map_cell_info(program, module, symbols) or_return
	fill_map_info(program, module, symbols) or_return
	if runtime_requirements.entry_point != 0 || len(runtime_requirements.tests) != 0 {
		append(&collected, Lower_Error{code = .Unsupported, feature = .Startup}) or_return
	}
	jobs := make([]Procedure_Job, len(module.functions), scratch_allocator) or_return
	for procedure in check.procedures(program) {
		assert(int(procedure.symbol) > 0 && int(procedure.symbol) < len(symbols))
		symbol := symbols[procedure.symbol]
		assert(symbol.space == .Function)
		job := &jobs[symbol.index]
		assert(job.program == nil, "duplicate checked procedure")
		job^ = Procedure_Job {
			program         = program,
			module          = module,
			procedure       = procedure,
			function        = module.functions[symbol.index],
			symbols         = symbols,
			default_context = default_context,
			errors          = make([dynamic]Lower_Error, virtual.arena_allocator(&module.functions[symbol.index].arena)) or_return,
			extern_names    = make([dynamic]string, virtual.arena_allocator(&module.functions[symbol.index].arena)) or_return,
		}
		job.function.target_features = procedure.target_features
		prepare_procedure(job, scratch_allocator) or_return
	}
	for &job in jobs {
		assert(job.program != nil, "missing checked procedure")
	}
	abi_plans := prepare_abi_plans(program, scratch_allocator) or_return
	layouts := prepare_layouts(check.type_store(program), scratch_allocator) or_return
	declarations := prepare_declarations(jobs, len(program.entities), scratch_allocator) or_return
	address_taken := scan_address_taken(program, scratch_allocator) or_return
	for &job in jobs {
		job.layouts = layouts
		job.declarations = declarations
		job.address_taken = address_taken
		job.abi_plans = &abi_plans
	}
	// The generated startup procedures lower before reachability, so helpers referenced only by dynamic
	// global initializers are marked reached instead of stubbed with an unreachable trap.
	startup_base := len(module.functions)
	append_startup_procedures(program, module, symbols, declarations, layouts, &abi_plans, default_context, &collected, allocator) or_return
	startup_roots := make([]u32, len(module.functions) - startup_base, scratch_allocator) or_return
	for index in startup_base ..< len(module.functions) { startup_roots[index - startup_base] = u32(index) }
	reached_globals := lower_reachable(program, module, jobs, startup_roots, symbols, worker_count, allocator, scratch_allocator) or_return
	for &job in jobs {
		merge_job_externs(module, &job) or_return
	}
	prune_unreached_global_errors(program, symbols, reached_globals, &collected) or_return
	for &job in jobs {
		if job.allocation_error != nil { return nil, job.allocation_error }
		append(&collected, ..job.errors[:]) or_return
	}
	_, merge_error := ir.blob_merge(module)
	if merge_error != nil { return nil, merge_error }
	errors = make([]Lower_Error, len(collected), allocator) or_return
	copy(errors, collected[:])
	return errors, nil
}
