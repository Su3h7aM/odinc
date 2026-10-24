package lower

import "base:runtime"
import "core:mem/virtual"
import "core:thread"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
Procedure_State :: struct {
	job:             ^Procedure_Job,
	builder:         ^ir.Builder,
	locals:          map[check.Entity_Id]Local_Binding,
	address_taken:   []bool,
	ast:             ^syntax.Ast,
	view:            check.View_Id,
	entry_control:   ir.Node_Id,
	failed:          bool,
	context_pointer: ir.Node_Id,
	local_entities:  [dynamic]check.Entity_Id,
	control_targets: [dynamic]Control_Target,
	call_signatures: [dynamic]Call_Signature,
	result_pointers: [dynamic]ir.Node_Id,
	struct_return:   ir.Node_Id,
	defers:          [dynamic]Deferred_Action,
}

@(private)
report_procedure_error :: proc(
	job: ^Procedure_Job,
	code: Lower_Code,
	feature: Lower_Feature,
	verify_code := ir.Verify_Code.None,
	abi_error := types.Plan_Error.None,
) {
	if job.allocation_error != nil { return }
	_, job.allocation_error = append(
		&job.errors,
		Lower_Error {
			code = code,
			feature = feature,
			entity = job.procedure.entity,
			node = job.procedure.body,
			source = job.procedure.source,
			function_index = u32(job.function.id),
			verify_code = verify_code,
			abi_error = abi_error,
		},
	)
}

@(private)
prepare_procedure :: proc(job: ^Procedure_Job, allocator: runtime.Allocator) -> (err: runtime.Allocator_Error) {
	store := check.type_store(job.program)
	descriptor := types.get(store, types.resolve_named(store, job.procedure.signature))
	assert(descriptor.kind == .Procedure && descriptor.convention == job.procedure.convention)
	assert(job.procedure.generated.kind != .None || len(descriptor.params) == len(job.procedure.parameters))
	by_pointer := make([]bool, len(descriptor.params), allocator) or_return
	for entity, index in job.procedure.parameters {
		assert(int(entity) > 0 && int(entity) < len(job.program.entities))
		by_pointer[index] = .By_Pointer in job.program.entities[entity].flags
	}
	plan: types.Abi_Plan
	plan_error: types.Plan_Error
	{
		context.temp_allocator = allocator
		if descriptor.c_vararg {
			// The tail of a C-variadic procedure is read with `c_va_arg`; only its fixed parameters have ABI pieces.
			plan, plan_error = types.plan_call_abi(store, job.procedure.signature, by_pointer, nil, allocator = allocator)
		} else {
			plan, plan_error = types.plan_abi(store, job.procedure.signature, by_pointer, allocator = allocator)
		}
	}
	if plan_error == .Out_Of_Memory { return .Out_Of_Memory }
	if plan_error != .None {
		report_procedure_error(job, .Abi, .Signature, abi_error = plan_error)
		return job.allocation_error
	}
	job.parameters = plan.params
	signature := abi_signature(plan, allocator) or_return
	job.function.signature = ir.add_signature(job.function, signature)
	return job.function.error
}

@(private)
piece_type :: proc(piece: types.Abi_Piece) -> ir.Value_Type {
	switch piece {
	case .I8:
		return .I8
	case .I16:
		return .I16
	case .I32:
		return .I32
	case .I64:
		return .I64
	case .F16:
		return .I16
	case .F32:
		return .F32
	case .F64:
		return .F64
	case .V128:
		return .V128
	case .Ptr:
		return .Ptr
	}
	unreachable()
}

@(private)
run_procedure :: proc(task: thread.Task) {
	job := cast(^Procedure_Job)task.data
	if len(job.errors) != 0 || job.allocation_error != nil { return }
	job.allocation_error = lower_procedure(job)
	if job.function.error != nil { job.allocation_error = job.function.error }
}

@(private)
lower_procedure :: proc(job: ^Procedure_Job) -> (err: runtime.Allocator_Error) {
	procedure := &job.procedure
	if procedure.generated.kind != .None {
		return lower_generated_procedure(job)
	}
	files := check.sources(job.program)
	assert(int(procedure.body.file) > 0 && int(procedure.body.file) <= len(files))
	ast := files[int(procedure.body.file) - 1].ast
	assert(ast != nil && int(procedure.body.node) > 0 && int(procedure.body.node) < len(ast.nodes))
	body := ast.nodes[procedure.body.node]
	assert(body.kind == .Block_Stmt)
	block := body.payload.(syntax.Block_Stmt)
	assert(int(block.stmts.first) + int(block.stmts.count) <= len(ast.extra))
	function := job.function
	if len(function.signatures[function.signature].results) > 2 {
		report_procedure_error(job, .Unsupported, .Result)
		return job.allocation_error
	}
	entry := ir.start(function)
	if function.error != nil { return function.error }
	builder := ir.builder_make(function.allocator, function, entry) or_return
	defer ir.builder_destroy(builder)
	allocator := virtual.arena_allocator(&function.arena)
	state := Procedure_State {
		job             = job,
		builder         = builder,
		locals          = make(map[check.Entity_Id]Local_Binding, allocator),
		address_taken   = job.address_taken,
		ast             = ast,
		view            = procedure.view,
		entry_control   = entry.control,
		local_entities  = make([dynamic]check.Entity_Id, allocator) or_return,
		control_targets = make([dynamic]Control_Target, allocator) or_return,
		call_signatures = make([dynamic]Call_Signature, allocator) or_return,
		result_pointers = make([dynamic]ir.Node_Id, allocator) or_return,
		defers          = make([dynamic]Deferred_Action, allocator) or_return,
	}
	for index := 0; index < len(job.parameters); {
		parameter := job.parameters[index]
		if parameter.attr == .Context {
			state.context_pointer = entry.params[index]
			index += 1
			continue
		}
		if parameter.source < 0 && parameter.attr == .Direct && parameter.type == .Ptr {
			if _, append_error := append(&state.result_pointers, entry.params[index]); append_error != nil { return append_error }
			index += 1
			continue
		}
		if parameter.source < 0 && parameter.attr == .Struct_Return {
			state.struct_return = entry.params[index]
			index += 1
			continue
		}
		span := parameter_span(job.parameters[index:])
		if !bind_parameter(&state, job.parameters[index:index + span], entry.params[index:index + span]) { return job.allocation_error }
		index += span
	}
	for entity in procedure.parameters {
		if state.locals[entity].kind != .None || .C_Variadic in job.program.entities[entity].flags { continue }
		if job.layouts[job.program.entities[entity].type].size != 0 {
			report_procedure_error(job, .Unsupported, .Parameter)
			return job.allocation_error
		}
		bind_local(&state, entity, 0, false)
	}
	for entity in procedure.results { bind_local(&state, entity, 0, true) }
	if state.failed { return job.allocation_error }
	for entity, index in procedure.results {
		argument := procedure.result_defaults[index]
		#partial switch argument.kind {
		case .Constant, .Value:
		case:
			continue
		}
		value: ir.Node_Id
		if argument.conversion != 0 {
			value = lower_declared_conversion(&state, procedure.body.node, argument.conversion)
		} else {
			value = lower_operand(&state, argument.value, state.job.program.entities[entity].type)
		}
		if state.failed { return job.allocation_error }
		store_result_entity(&state, entity, value)
	}
	if function.error != nil { return function.error }
	lower_statement(&state, procedure.body.node)
	if function.error != nil { return function.error }
	if state.failed { return job.allocation_error }
	if builder.control != 0 {
		if len(function.signatures[function.signature].results) != 0 {
			ir.emit_unreachable(builder)
		} else {
			ir.emit_return(builder)
		}
	}
	switch finish_error in ir.builder_finish(builder) {
	case runtime.Allocator_Error:
		return finish_error
	case ir.Verify_Code:
		if finish_error != .None {
			report_procedure_error(job, .Verification, .None, verify_code = finish_error)
		}
	case nil:
	}
	return job.allocation_error
}
