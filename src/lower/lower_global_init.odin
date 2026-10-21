package lower

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "oc:check"
import "oc:ir"
import "oc:syntax"

// Generated startup procedures. `init.globals` stores each dynamic package variable in dependency order, then calls the
// @(init) procedures. `fini.program` calls the @(fini) procedures. The driver calls them from `_start` around `main`.
GLOBAL_INITIALIZER_NAME :: "init.globals"
PROGRAM_FINALIZER_NAME :: "fini.program"

@(private)
Startup_Body :: proc(state: ^Procedure_State)

@(private)
append_startup_procedures :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	symbols: []ir.Symbol_Ref,
	declarations: []Procedure_Declaration,
	layouts: []Type_Layout,
	default_context: ir.Symbol_Ref,
	errors: ^[dynamic]Lower_Error,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	if len(program.global_initialization) > 0 || len(program.runtime.init_procedures) > 0 || program.runtime.init_context != 0 {
		append_generated_procedure(
			program,
			module,
			symbols,
			declarations,
			layouts,
			default_context,
			errors,
			GLOBAL_INITIALIZER_NAME,
			lower_global_initializers,
			allocator,
		) or_return
	}
	if len(program.runtime.fini_procedures) == 0 { return nil }
	return append_generated_procedure(
		program,
		module,
		symbols,
		declarations,
		layouts,
		default_context,
		errors,
		PROGRAM_FINALIZER_NAME,
		lower_program_finalizers,
		allocator,
	)
}

@(private)
append_generated_procedure :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	symbols: []ir.Symbol_Ref,
	declarations: []Procedure_Declaration,
	layouts: []Type_Layout,
	default_context: ir.Symbol_Ref,
	errors: ^[dynamic]Lower_Error,
	name: string,
	body: Startup_Body,
	allocator: runtime.Allocator,
) -> runtime.Allocator_Error {
	function_index := u32(len(module.functions))
	function := ir.function_make(allocator, ir.Function_Id(function_index), name, 0) or_return
	if _, append_error := append(&module.functions, function); append_error != nil {
		ir.function_destroy(function)
		return append_error
	}
	function.signature = ir.add_signature(function, ir.Signature{.Odin, false, nil, nil})
	entry := ir.start(function)
	if function.error != nil {
		append(errors, Lower_Error{code = .Verification}) or_return
		return nil
	}
	builder := ir.builder_make(function.allocator, function, entry) or_return
	defer ir.builder_destroy(builder)

	allocator_arena := virtual.arena_allocator(&function.arena)
	job := Procedure_Job {
		program         = program,
		module          = module,
		function        = function,
		symbols         = symbols,
		default_context = default_context,
		declarations    = declarations,
		layouts         = layouts,
		errors          = make([dynamic]Lower_Error, allocator_arena) or_return,
	}
	state := Procedure_State {
		job             = &job,
		builder         = builder,
		locals          = make(map[check.Entity_Id]Local_Binding, allocator_arena),
		address_taken   = make([]bool, len(program.entities), allocator_arena) or_return,
		entry_control   = entry.control,
		local_entities  = make([dynamic]check.Entity_Id, allocator_arena) or_return,
		control_targets = make([dynamic]Control_Target, allocator_arena) or_return,
		call_signatures = make([dynamic]Call_Signature, allocator_arena) or_return,
		result_pointers = make([dynamic]ir.Node_Id, allocator_arena) or_return,
		context_pointer = ir.symbol_addr(function, default_context),
	}
	body(&state)
	if !state.failed && function.error == nil {
		ir.emit_return(builder)
		switch finish_error in ir.builder_finish(builder) {
		case runtime.Allocator_Error:
			return finish_error
		case ir.Verify_Code:
			if finish_error != .None { append(errors, Lower_Error{code = .Verification, verify_code = finish_error}) or_return }
		case nil:
		}
	}
	if job.allocation_error != nil { return job.allocation_error }
	for lower_error in job.errors { append(errors, lower_error) or_return }
	return nil
}

@(private)
lower_global_initializers :: proc(state: ^Procedure_State) {
	program := state.job.program
	function := state.job.function
	call_init_context(state)
	for entity in program.global_initialization {
		global := find_global(program, entity)
		assert(global != nil)
		state.job.procedure.body.file = global.initializer_node.file
		state.ast = program.files[global.initializer_node.file].ast
		span := state.ast.nodes[global.initializer_node.node]
		state.job.procedure.source = check.Source_Span {
			file  = global.initializer_node.file,
			start = span.start,
			end   = span.end,
		}
		state.view = global.initializer_view
		value := lower_global_initializer(state, global, global.initializer_node.node)
		if state.failed || function.error != nil { return }
		address := ir.symbol_addr(function, state.job.symbols[global.symbol])
		if global.thread_local { address = ir.tls_addr(function, state.job.symbols[global.symbol]) }
		lower_store(state, address, value, global.type)
		if state.failed || function.error != nil { return }
	}
	call_startup_procedures(state, program.runtime.init_procedures)
}

// Evaluates a dynamic global initializer. A top-level address of a composite literal names fresh storage that must
// outlive startup, so it is materialized as a hidden global the way slice backing already is; any other operand keeps
// the existing path so `&other_global` still aliases its storage. Matches upstream `lb_build_addr`, which creates a
// global for `&T{...}` in startup procedures and a local elsewhere.
@(private)
lower_global_initializer :: proc(state: ^Procedure_State, global: ^check.Global, node: syntax.Node_Index) -> ir.Node_Id {
	operand, is_literal_address := global_literal_address_operand(state, node)
	if !is_literal_address { return lower_value(state, node) }
	function := state.job.function
	module := state.job.module
	if module == nil { return lower_value(state, node) }
	info := lower_info(state, operand)
	if state.failed { return 0 }
	layout := state.job.layouts[info.type]
	if layout.error != .None || layout.size < 0 || layout.size > i64(max(u32)) { return lower_fail(state, operand, .Expression) }
	index := len(module.globals)
	name := fmt.aprintf("__odinc_internal_global_address_%d", index, allocator = virtual.arena_allocator(&module.arena))
	if _, error := append(
		&module.globals,
		ir.Global{name = name, size = u32(layout.size), align = max(u32(layout.align), global.alignment), mutable = true, tls = global.thread_local},
	); error != nil {
		state.job.allocation_error = error
		state.failed = true
		return 0
	}
	reference := ir.Symbol_Ref {
		space = .Global,
		index = u32(index),
	}
	backing := ir.symbol_addr(function, reference)
	if global.thread_local { backing = ir.tls_addr(function, reference) }
	value := lower_value(state, operand)
	if state.failed || function.error != nil { return 0 }
	lower_store(state, backing, value, info.type)
	if state.failed || function.error != nil { return 0 }
	return backing
}

// The composite literal under a top-level address operator, through any parentheses. Anything else, including an
// address of existing storage, is not a fresh literal.
@(private)
global_literal_address_operand :: proc(state: ^Procedure_State, node: syntax.Node_Index) -> (syntax.Node_Index, bool) {
	current := node
	for state.ast.nodes[current].kind == .Paren_Expr {
		current = state.ast.nodes[current].payload.(syntax.Paren_Expr).expr
	}
	if state.ast.nodes[current].kind != .Unary_Expr { return 0, false }
	unary := state.ast.nodes[current].payload.(syntax.Unary_Expr)
	if unary.op.kind != .And { return 0, false }
	operand := unary.expr
	for state.ast.nodes[operand].kind == .Paren_Expr {
		operand = state.ast.nodes[operand].payload.(syntax.Paren_Expr).expr
	}
	if state.ast.nodes[operand].kind != .Comp_Lit { return 0, false }
	return operand, true
}

@(private)
lower_program_finalizers :: proc(state: ^Procedure_State) {
	call_startup_procedures(state, state.job.program.runtime.fini_procedures)
}

// Calls each procedure with its implicit context only, as the startup code does: no parameters, no results.
@(private)
call_startup_procedures :: proc(state: ^Procedure_State, procedures: []check.Ordered_Procedure) {
	function := state.job.function
	allocator := virtual.arena_allocator(&function.arena)
	for procedure in procedures {
		if state.failed || function.error != nil { return }
		declaration := state.job.declarations[procedure.entity]
		parameter_count := len(declaration.signature.params)
		if declaration.type == 0 || parameter_count > 1 || (parameter_count == 1 && declaration.signature.params[0].attr != .Context) {
			entity := state.job.program.entities[procedure.entity]
			span := state.job.program.files[entity.declaration.file].ast.nodes[entity.declaration.node]
			source := check.Source_Span {
				file  = entity.declaration.file,
				start = span.start,
				end   = span.end,
			}
			if _, error := append(&state.job.errors, Lower_Error{code = .Unsupported, feature = .Startup, source = source});
			   error != nil { function.error = error }
			state.failed = true
			return
		}
		arguments, arguments_error := make([]ir.Node_Id, parameter_count, allocator)
		if arguments_error != nil {
			function.error = arguments_error
			return
		}
		if parameter_count == 1 { arguments[0] = state.context_pointer }
		id := call_signature(state, declaration)
		if function.error != nil { return }
		callee := ir.symbol_addr(function, declaration.symbol)
		call := ir.call(function, state.builder.control, ir.variable_get(state.builder, ir.MEMORY_VARIABLE), callee, id, arguments)
		memory := ir.add_node(function, .Proj, .Memory, {call}, {index = 0})
		ir.variable_set(state.builder, ir.MEMORY_VARIABLE, memory)
	}
}

@(private)
find_global :: proc(program: ^check.Checked_Program, entity: check.Entity_Id) -> ^check.Global {
	for &global in check.globals(program) {
		if global.entity == entity { return &global }
	}
	return nil
}
