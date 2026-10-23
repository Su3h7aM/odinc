package analysis

import "base:runtime"
import "oc:check"
import "oc:syntax"
import "oc:types"

// The atomic operation a builtin is, with whether it reads and writes, or a fence.
atomic_builtin :: proc(kind: check.Builtin_Kind) -> (known, fence: bool) {
	#partial switch kind {
	case .Atomic_Thread_Fence, .Atomic_Signal_Fence:
		return true, true
	case .Volatile_Load,
	     .Volatile_Store,
	     .Atomic_Load,
	     .Atomic_Store,
	     .Atomic_Add,
	     .Atomic_Sub,
	     .Atomic_And,
	     .Atomic_Nand,
	     .Atomic_Or,
	     .Atomic_Xor,
	     .Atomic_Exchange,
	     .Atomic_Compare_Exchange_Strong,
	     .Atomic_Compare_Exchange_Weak,
	     .Atomic_Load_Explicit,
	     .Atomic_Store_Explicit,
	     .Atomic_Add_Explicit,
	     .Atomic_Sub_Explicit,
	     .Atomic_And_Explicit,
	     .Atomic_Nand_Explicit,
	     .Atomic_Or_Explicit,
	     .Atomic_Xor_Explicit,
	     .Atomic_Exchange_Explicit,
	     .Atomic_Compare_Exchange_Strong_Explicit,
	     .Atomic_Compare_Exchange_Weak_Explicit:
		return true, false
	}
	return false, false
}

atomic_is_weak :: proc(kind: check.Builtin_Kind) -> bool {
	return kind == .Atomic_Compare_Exchange_Weak || kind == .Atomic_Compare_Exchange_Weak_Explicit
}

// Whether a call event consumes both results of its call.
atomic_tuple_use :: proc(a: ^Atomics, event: Event) -> bool {
	parent := event.parent
	for parent != 0 {
		candidate := a.run.events[parent]
		ast := atomic_ast(a, candidate.expression.view)
		if ast.nodes[candidate.expression.node].kind != .Paren_Expr { break }
		parent = candidate.parent
	}
	if parent == 0 { return false }
	context_event := a.run.events[parent]
	ast := atomic_ast(a, context_event.expression.view)
	#partial switch payload in ast.nodes[context_event.expression.node].payload {
	case syntax.Value_Decl:
		return syntax.node_list(ast, payload.names) != nil && len(syntax.node_list(ast, payload.names)) > 1 && len(syntax.node_list(ast, payload.values)) == 1
	case syntax.Assign_Stmt:
		return len(syntax.node_list(ast, payload.lhs)) > 1 && len(syntax.node_list(ast, payload.rhs)) == 1
	case syntax.Return_Stmt:
		if len(syntax.node_list(ast, payload.results)) != 1 { return false }
		checked := a.program.procedure_list[a.run.procedures[event.procedure].checked_index]
		return len(types.get(a.program.type_data, checked.signature).results) > 1
	}
	return false
}

atomic_collect :: proc(a: ^Atomics) -> runtime.Allocator_Error {
	for procedure, index in a.run.procedures[1:] {
		id := Procedure_Id(index + 1)
		for event in a.run.events[procedure.events.first:][:procedure.events.count] {
			if event.kind != .Call { continue }
			plan := check.plan(a.program, event.plan)
			if plan == nil { continue }
			call := Atomic_Call {
				call      = event.expression,
				procedure = id,
			}
			#partial switch p in plan^ {
			case check.Builtin_Plan:
				kind := check.builtin_kind(a.program, p.builtin)
				if known, _ := atomic_builtin(kind); !known { continue }
				call.kind = kind
				call.tuple = atomic_tuple_use(a, event)
			case check.Call_Plan:
				data, ok := atomic_procedure_data(a, p.entity)
				if !ok || data.atomic.futex == .None { continue }
				call.futex = data.atomic.futex
			case:
				continue
			}
			a.call_index[call.call] = len(a.calls)
			append(&a.calls, call) or_return
		}
	}
	return nil
}

atomic_create :: proc(a: ^Atomics, id: Procedure_Id) -> ^Atomic_Procedure {
	fresh := !a.procedures[id].ready
	p := atomic_procedure(a, id)
	if fresh { append(&a.created, id) }
	return p
}

atomic_record_fences :: proc(a: ^Atomics) {
	for call in a.calls {
		_, fence := atomic_builtin(call.kind)
		weak := atomic_is_weak(call.kind)
		if !(fence || weak || call.futex == .Wake) { continue }
		p := atomic_create(a, call.procedure)
		if !fence { continue }
		arguments := atomic_call_arguments(a, call.call.view, call.call.node)
		if len(arguments) == 0 { continue }
		order := atomic_order_of(a, call.call.view, arguments[0])
		signal := call.kind == .Atomic_Signal_Fence
		if atomic_acquires(order) { append(&p.signal_acquires if signal else &p.acquires, call.call.node) }
		if atomic_releases(order) { append(&p.signal_releases if signal else &p.releases, call.call.node) }
		if order == .Seq_Cst && !signal { p.has_seq_cst = true }
	}
}

// What an operation does with its orderings, explicit or by default.
Atomic_Effect_Order :: struct {
	explicit:      bool,
	order:         check.Atomic_Order,
	failure:       check.Atomic_Order,
	reads, writes: bool,
}

atomic_operation :: proc(a: ^Atomics, call: Atomic_Call) -> (operation: Atomic_Effect_Order, wake: bool) {
	operation = {
		explicit = true,
		order    = .Seq_Cst,
		failure  = .Relaxed,
		reads    = true,
		writes   = true,
	}
	arguments := atomic_call_arguments(a, call.call.view, call.call.node)
	argument_order :: proc(a: ^Atomics, call: Atomic_Call, arguments: []syntax.Node_Index, index: int) -> check.Atomic_Order {
		if index >= len(arguments) { return .Seq_Cst }
		return atomic_order_of(a, call.call.view, arguments[index])
	}
	switch call.futex {
	case .None:
		#partial switch call.kind {
		case .Atomic_Store:
			operation.explicit, operation.reads = false, false
		case .Atomic_Store_Explicit:
			operation.order, operation.reads = argument_order(a, call, arguments, 2), false
		case .Atomic_Load:
			operation.explicit, operation.writes = false, false
		case .Atomic_Load_Explicit:
			operation.order, operation.writes = argument_order(a, call, arguments, 1), false
		case .Atomic_Add_Explicit,
		     .Atomic_Sub_Explicit,
		     .Atomic_And_Explicit,
		     .Atomic_Nand_Explicit,
		     .Atomic_Or_Explicit,
		     .Atomic_Xor_Explicit,
		     .Atomic_Exchange_Explicit:
			operation.order = argument_order(a, call, arguments, 2)
		case .Atomic_Compare_Exchange_Strong_Explicit, .Atomic_Compare_Exchange_Weak_Explicit:
			operation.order = argument_order(a, call, arguments, 3)
			operation.failure = argument_order(a, call, arguments, 4)
		case:
			operation.explicit = false
		}
	case .Wait:
		operation.explicit, operation.order, operation.writes = false, .Relaxed, false
	case .Wake:
		wake = true
	}
	return
}
