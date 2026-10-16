package ir

import "base:runtime"
import "core:mem/virtual"

Memory_Order :: enum u8 {
	Plain,
	Volatile,
	Relaxed,
	Acquire,
	Release,
	Acq_Rel,
	Seq_Cst,
}

Rmw_Op :: enum u8 {
	Add,
	Sub,
	And,
	Nand,
	Or,
	Xor,
	Xchg,
}

Access_Info :: struct {
	align_log2:    u8,
	order:         Memory_Order,
	failure_order: Memory_Order,
	rmw:           Rmw_Op,
	weak:          bool,
	signal:        bool,
	value_type:    Value_Type, // the value of a `Load_Ordered`
}

Slot_Info :: struct {
	size:  u32,
	align: u32,
}

// The kind gives the meaning; the accessors assert it.
Node_Data :: struct #raw_union {
	int_value:  i64,
	float_bits: u64,
	index:      u32,
	symbol:     Symbol_Ref,
	access:     Access_Info,
	slot:       Slot_Info,
}

Node :: struct {
	kind:        Node_Kind,
	type:        Value_Type,
	flags:       Node_Flags,
	input_count: u16,
	first_input: u32,
	data:        Node_Data,
}

// Never copy or move a `Function`: its arrays hold the address of `arena`. Use `function_make`.
Function :: struct {
	id:         Function_Id,
	name:       string,
	signature:  Signature_Id,
	nodes:      #soa[dynamic]Node,
	edges:      [dynamic]Node_Id,
	tables:     [dynamic][]i64,
	signatures: [dynamic]Signature,
	blobs:      [dynamic]Data_Blob,
	start:      Node_Id,
	stop:       Node_Id,
	arena:      virtual.Arena,
	allocator:  runtime.Allocator,
	error:      runtime.Allocator_Error,
}

Use :: struct {
	user: Node_Id,
	slot: u16,
}

// `uses[first[n]:first[n+1]]` are the uses of node `n`, ordered by (user id, slot).
Use_Table :: struct {
	first: []u32,
	uses:  []Use,
}

#assert(size_of(Node_Data) == 8)

function_make :: proc(allocator: runtime.Allocator, id: Function_Id, name: string, signature: Signature_Id) -> (fn: ^Function, err: runtime.Allocator_Error) {
	fn = new(Function, allocator) or_return
	defer if err != nil {
		free(fn, allocator)
		fn = nil
	}
	fn^ = {
		id        = id,
		signature = signature,
		allocator = allocator,
	}
	virtual.arena_init_growing(&fn.arena) or_return
	defer if err != nil {
		virtual.arena_destroy(&fn.arena)
	}

	arena_alloc := virtual.arena_allocator(&fn.arena)
	fn.name = string(runtime.mem_alloc_bytes(len(name), 1, arena_alloc) or_return)
	copy(transmute([]byte)fn.name, name)
	fn.nodes = make_soa(#soa[dynamic]Node, 0, 64, arena_alloc) or_return
	fn.edges = make([dynamic]Node_Id, 0, 128, arena_alloc) or_return
	fn.tables = make([dynamic][]i64, arena_alloc) or_return
	fn.signatures = make([dynamic]Signature, arena_alloc) or_return
	fn.blobs = make([dynamic]Data_Blob, arena_alloc) or_return
	append_soa(&fn.nodes, Node{}) or_return
	return fn, nil
}

function_destroy :: proc(fn: ^Function) {
	virtual.arena_destroy(&fn.arena)
	free(fn, fn.allocator)
}

// Never folds, interns or checks input types; that is the builder's and the verifier's job.
// Failure is sticky in `fn.error` and returns `NODE_NONE`.
add_node :: proc(fn: ^Function, kind: Node_Kind, type: Value_Type, inputs: []Node_Id = nil, data := Node_Data{}, flags := Node_Flags{}) -> Node_Id {
	info := &kind_info[kind]
	assert(kind != .Invalid && kind != .Removed)
	assert(len(inputs) >= int(info.min_inputs) && len(inputs) <= int(info.max_inputs), "input count outside the kind's arity")
	assert(type in info.result, "result type not allowed for the kind")

	if fn.error != nil {
		return NODE_NONE
	}
	first_input := len(fn.edges)
	if _, err := append(&fn.edges, ..inputs); err != nil {
		fn.error = err
		return NODE_NONE
	}
	node := Node {
		kind        = kind,
		type        = type,
		flags       = flags,
		input_count = u16(len(inputs)),
		first_input = u32(first_input),
		data        = data,
	}
	if _, err := append_soa(&fn.nodes, node); err != nil {
		fn.error = err
		return NODE_NONE
	}
	return Node_Id(len(fn.nodes) - 1)
}

add_table :: proc(fn: ^Function, values: []i64) -> (index: u32, ok: bool) {
	if fn.error != nil {
		return 0, false
	}
	copied, copy_err := make([]i64, len(values), virtual.arena_allocator(&fn.arena))
	if copy_err != nil {
		fn.error = copy_err
		return 0, false
	}
	copy(copied, values)
	if _, err := append(&fn.tables, copied); err != nil {
		fn.error = err
		return 0, false
	}
	return u32(len(fn.tables) - 1), true
}

// Valid until the next node is added.
node_inputs :: proc(fn: ^Function, id: Node_Id) -> []Node_Id {
	first := fn.nodes.first_input[id]
	return fn.edges[first:first + u32(fn.nodes.input_count[id])]
}

node_input :: proc(fn: ^Function, id: Node_Id, slot: int) -> Node_Id {
	assert(slot < int(fn.nodes.input_count[id]))
	return fn.edges[int(fn.nodes.first_input[id]) + slot]
}

set_input :: proc(fn: ^Function, id: Node_Id, slot: int, input: Node_Id) {
	assert(slot < int(fn.nodes.input_count[id]))
	fn.edges[int(fn.nodes.first_input[id]) + slot] = input
}

// Shrinks arity in place; the dropped edges stay in the arena.
set_input_count :: proc(fn: ^Function, id: Node_Id, count: int) {
	assert(count <= int(fn.nodes.input_count[id]))
	fn.nodes.input_count[id] = u16(count)
}

node_int_value :: proc(fn: ^Function, id: Node_Id) -> i64 {
	assert(fn.nodes.kind[id] == .Const_Int || fn.nodes.kind[id] == .Ptr_Offset)
	return fn.nodes.data[id].int_value
}

node_float_bits :: proc(fn: ^Function, id: Node_Id) -> u64 {
	assert(fn.nodes.kind[id] == .Const_Float)
	return fn.nodes.data[id].float_bits
}

node_index :: proc(fn: ^Function, id: Node_Id) -> u32 {
	assert(fn.nodes.kind[id] in Index_Kinds)
	return fn.nodes.data[id].index
}

node_access :: proc(fn: ^Function, id: Node_Id) -> Access_Info {
	assert(fn.nodes.kind[id] in Access_Kinds)
	return fn.nodes.data[id].access
}

node_slot :: proc(fn: ^Function, id: Node_Id) -> Slot_Info {
	assert(fn.nodes.kind[id] == .Stack_Slot)
	return fn.nodes.data[id].slot
}

// Ids stay stable: the node becomes `.Removed` with no inputs. Callers ensure it has no users.
remove_node :: proc(fn: ^Function, id: Node_Id) {
	assert(id != NODE_NONE && id != fn.start && id != fn.stop)
	fn.nodes.kind[id] = .Removed
	fn.nodes.type[id] = .None
	fn.nodes.flags[id] = {}
	fn.nodes.input_count[id] = 0
	fn.nodes.data[id] = {}
}

uses_build :: proc(fn: ^Function, allocator: runtime.Allocator) -> (table: Use_Table, err: runtime.Allocator_Error) {
	node_count := len(fn.nodes)
	table.first = make([]u32, node_count + 1, allocator) or_return
	defer if err != nil {
		delete(table.first, allocator)
	}

	use_count: u32
	for user in 0 ..< node_count {
		for input in node_inputs(fn, Node_Id(user)) {
			if input != NODE_NONE {
				table.first[int(input) + 1] += 1
				use_count += 1
			}
		}
	}
	for node in 0 ..< node_count {
		table.first[node + 1] += table.first[node]
	}

	table.uses = make([]Use, use_count, allocator) or_return
	defer if err != nil {
		delete(table.uses, allocator)
	}
	cursor := make([]u32, node_count, allocator) or_return
	defer delete(cursor, allocator)
	copy(cursor, table.first[:node_count])

	for user in 0 ..< node_count {
		for input, slot in node_inputs(fn, Node_Id(user)) {
			if input != NODE_NONE {
				table.uses[cursor[input]] = Use {
					user = Node_Id(user),
					slot = u16(slot),
				}
				cursor[input] += 1
			}
		}
	}
	return table, nil
}

uses_of :: proc(table: Use_Table, id: Node_Id) -> []Use {
	return table.uses[table.first[id]:table.first[int(id) + 1]]
}

use_table_destroy :: proc(table: ^Use_Table, allocator: runtime.Allocator) {
	delete(table.first, allocator)
	delete(table.uses, allocator)
	table^ = {}
}

@(private = "file")
Index_Kinds :: bit_set[Node_Kind]{.Proj, .Switch, .Stack_Alloc, .Ptr_Index, .Call, .Target_Op}

@(private = "file")
Access_Kinds :: bit_set[Node_Kind]{.Load, .Load_Ordered, .Store, .Atomic_Rmw, .Atomic_Cas, .Fence}
