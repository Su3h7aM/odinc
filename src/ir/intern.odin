package ir

// Hash-consing of pure nodes (section 11): identical pure constructions share one node.
// The table holds node ids only; the key (kind, type, inputs, the data fields the kind
// defines) is reread from the node arrays on every probe, so a stale slot after `set_input`,
// `remove_node` or `loop_collapse` only costs sharing, never correctness. `loop_collapse`
// rebuilds the table to drop the stale slots; nothing else touches it.

INTERN_INITIAL_CAPACITY :: 16

interned_node :: proc(fn: ^Function, kind: Node_Kind, type: Value_Type, inputs: []Node_Id, data: Node_Data, flags: Node_Flags) -> Node_Id {
	assert(is_pure(kind))
	if fn.error != nil {
		return NODE_NONE
	}
	if found := intern_lookup(fn, kind, type, inputs, data); found != NODE_NONE {
		return found
	}
	for fn.intern_mask == 0 || (fn.intern_count + 1) * 4 > u32(len(fn.intern_table)) * 3 {
		intern_grow(fn)
		if fn.error != nil {
			return NODE_NONE
		}
	}
	id := add_node(fn, kind, type, inputs, data, flags)
	if id == NODE_NONE {
		return NODE_NONE
	}
	intern_insert(fn, id)
	return id
}

intern_lookup :: proc(fn: ^Function, kind: Node_Kind, type: Value_Type, inputs: []Node_Id, data: Node_Data) -> Node_Id {
	if fn.intern_mask == 0 {
		return NODE_NONE
	}
	slot := intern_hash(kind, type, inputs, data) & u64(fn.intern_mask)
	for {
		id := fn.intern_table[slot]
		if id == NODE_NONE {
			return NODE_NONE
		}
		if intern_key_equal(fn, id, kind, type, inputs, data) {
			return id
		}
		slot = (slot + 1) & u64(fn.intern_mask)
	}
}

// Records `id` under its current key. A duplicate key keeps the first node.
intern_insert :: proc(fn: ^Function, id: Node_Id) {
	assert(fn.intern_mask != 0)
	kind := fn.nodes.kind[id]
	type := fn.nodes.type[id]
	inputs := node_inputs(fn, id)
	data := fn.nodes.data[id]
	slot := intern_hash(kind, type, inputs, data) & u64(fn.intern_mask)
	for {
		existing := fn.intern_table[slot]
		if existing == NODE_NONE {
			fn.intern_table[slot] = id
			fn.intern_count += 1
			return
		}
		if intern_key_equal(fn, existing, kind, type, inputs, data) {
			return
		}
		slot = (slot + 1) & u64(fn.intern_mask)
	}
}

// Drops every slot and reinserts the live pure nodes in id order. Duplicates that a rewrite
// created stay separate nodes; later lookups find the first.
intern_rebuild :: proc(fn: ^Function) {
	if fn.error != nil {
		return
	}
	fn.intern_table = nil
	fn.intern_mask = 0
	fn.intern_count = 0
	for index in 1 ..< len(fn.nodes) {
		id := Node_Id(index)
		if !is_pure(fn.nodes.kind[id]) {
			continue
		}
		for fn.intern_mask == 0 || (fn.intern_count + 1) * 4 > u32(len(fn.intern_table)) * 3 {
			intern_grow(fn)
			if fn.error != nil {
				return
			}
		}
		intern_insert(fn, id)
	}
}

@(private = "file")
intern_grow :: proc(fn: ^Function) {
	capacity := 2 * len(fn.intern_table) if len(fn.intern_table) != 0 else INTERN_INITIAL_CAPACITY
	grown, err := make([]Node_Id, capacity, growth_allocator(fn))
	if err != nil {
		fn.error = err
		return
	}
	previous := fn.intern_table
	fn.intern_table = grown
	fn.intern_mask = u32(capacity - 1)
	fn.intern_count = 0
	for id in previous {
		if id != NODE_NONE && is_pure(fn.nodes.kind[id]) {
			intern_insert(fn, id)
		}
	}
}

@(private = "file")
intern_mix :: proc(hash: u64, value: u64) -> u64 {
	return (hash ~ value) * 1099511628211
}

// Semantic hash: exactly the fields `intern_key_equal` compares.
@(private = "file")
intern_hash :: proc(kind: Node_Kind, type: Value_Type, inputs: []Node_Id, data: Node_Data) -> u64 {
	hash := u64(0xcbf29ce484222325)
	hash = intern_mix(hash, u64(kind))
	hash = intern_mix(hash, u64(type))
	hash = intern_mix(hash, u64(len(inputs)))
	for input in inputs {
		hash = intern_mix(hash, u64(input))
	}
	#partial switch kind {
	case .Const_Int, .Ptr_Offset:
		hash = intern_mix(hash, u64(data.int_value))
	case .Const_Float:
		hash = intern_mix(hash, data.float_bits)
	case .Symbol_Addr, .Tls_Addr:
		hash = intern_mix(hash, u64(data.symbol.space))
		hash = intern_mix(hash, u64(data.symbol.index))
	case .Ptr_Index:
		hash = intern_mix(hash, u64(data.index))
	}
	return hash
}

// Semantic key: kind, type, inputs, and the data fields the kind defines. Flags are not part
// of the key; every constructor passes the same flags for a kind.
@(private = "file")
intern_key_equal :: proc(fn: ^Function, id: Node_Id, kind: Node_Kind, type: Value_Type, inputs: []Node_Id, data: Node_Data) -> bool {
	if fn.nodes.kind[id] != kind || fn.nodes.type[id] != type {
		return false
	}
	if int(fn.nodes.input_count[id]) != len(inputs) {
		return false
	}
	first := int(fn.nodes.first_input[id])
	for input, slot in inputs {
		if fn.edges[first + slot] != input {
			return false
		}
	}
	#partial switch kind {
	case .Const_Int, .Ptr_Offset:
		return fn.nodes.data[id].int_value == data.int_value
	case .Const_Float:
		return fn.nodes.data[id].float_bits == data.float_bits
	case .Symbol_Addr, .Tls_Addr:
		return fn.nodes.data[id].symbol == data.symbol
	case .Ptr_Index:
		return fn.nodes.data[id].index == data.index
	case:
		return true
	}
}
