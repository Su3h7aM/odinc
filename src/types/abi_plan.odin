package types

Abi_Convention :: enum u8 {
	Odin,
	Contextless,
	C,
}

// Abi_Piece is the machine class of one register-sized piece. V128 is a whole
// SSE register holding two eightbytes (SSE then SSE_Up).
Abi_Piece :: enum u8 {
	I8,
	I16,
	I32,
	I64,
	F16,
	F32,
	F64,
	V128,
	Ptr,
}

Abi_Attr :: enum u8 {
	Direct,
	Indirect,
	By_Value,
	Struct_Return,
	Context,
}

Abi_Extension :: enum u8 {
	None,
	Sign,
	Zero,
}

// Abi_Param is one physical parameter. source is the index of the procedure
// parameter it carries, or -1 for hidden ones (sret, split-result pointers,
// context). A source parameter classified into registers becomes consecutive
// Direct params. For Direct, size is the number of significant bytes of the
// piece (less than the piece width for odd-sized aggregates) and align its
// stack alignment; for Indirect, By_Value and Struct_Return they describe the
// object behind the pointer (By_Value align is max(8, type alignment)).
Abi_Param :: struct {
	source: i32,
	type:   Abi_Piece,
	attr:   Abi_Attr,
	ext:    Abi_Extension,
	size:   u32,
	align:  u16,
}

Abi_Result :: struct {
	type: Abi_Piece,
	ext:  Abi_Extension,
	size: u32,
}

// Abi_Plan is the physical signature of a procedure: hidden sret first, then the
// source parameters, split-result pointers, and the context pointer last for
// the Odin convention. Release it with destroy_plan.
Abi_Plan :: struct {
	convention: Abi_Convention,
	variadic:   bool,
	params:     []Abi_Param,
	results:    []Abi_Result,
}

Plan_Error :: enum u8 {
	None,
	Invalid_Type,
	Incomplete_Type,
	Recursive_Value,
	Poison,
	Unsupported_Convention,
	Unsupported_Return,
	Out_Of_Memory,
}

destroy_plan :: proc(plan: ^Abi_Plan, allocator := context.allocator) {
	delete(plan.params, allocator)
	delete(plan.results, allocator)
	plan^ = Abi_Plan{}
}

INTEGER_ARGUMENT_REGISTERS :: 6
SSE_ARGUMENT_REGISTERS :: 8

@(private = "file")
Registers :: struct {
	integer, sse: int,
}

@(private = "file")
Piece_Info :: struct {
	type:  Abi_Piece,
	size:  u32,
	align: u16,
}

@(private = "file")
Piece_Run :: struct {
	pieces: [MAX_CLASS_EIGHTBYTES]Piece_Info,
	count:  int,
}

// plan_abi computes the physical signature of a Kind.Procedure type for Linux
// x86-64, reproducing lb_get_abi_info of the official compiler: the 6 INTEGER
// and 8 SSE register counters (hidden pointers are not counted), ran_out_of_regs,
// Indirect for MEMORY aggregates under the Odin and Contextless conventions and
// By_Value under the C ones, split results through pointer parameters for Odin
// and Contextless, and sub-word integer extension. by_pointer marks #by_ptr
// parameters (indexed like the procedure's params; may be shorter or nil). The
// procedure's variadic flag means C varargs. The plan is allocated with
// allocator.
plan_abi :: proc(
	store: ^Store,
	procedure: Type_Id,
	by_pointer: []bool = nil,
	config := DEFAULT_LAYOUT,
	allocator := context.allocator,
) -> (
	plan: Abi_Plan,
	err: Plan_Error,
) {
	proc_type := get(store, resolve_named(store, procedure))
	assert(proc_type.kind == .Procedure)
	convention: Abi_Convention
	#partial switch proc_type.convention {
	case .Odin:
		convention = .Odin
	case .Contextless:
		convention = .Contextless
	case .C, .Stdcall, .Fastcall, .SysV:
		convention = .C
	case:
		return {}, .Unsupported_Convention
	}
	params := make([dynamic]Abi_Param, allocator)
	results := make([dynamic]Abi_Result, allocator)
	defer if err != .None {
		delete(params)
		delete(results)
	}

	split_results := convention != .C && len(proc_type.results) > 1
	switch len(proc_type.results) {
	case 0:
	case 1:
		err = plan_result(store, proc_type.results[0], true, config, &params, &results)
	case:
		return_id := proc_type.results[len(proc_type.results) - 1]
		if !split_results {
			return_id = tuple_of(store, proc_type.results)
		}
		err = plan_result(store, return_id, false, config, &params, &results)
		if !split_results { _ = pop(&store.types) }
	}
	if err != .None { return {}, err }

	registers := Registers{INTEGER_ARGUMENT_REGISTERS, SSE_ARGUMENT_REGISTERS}
	for param_id, index in proc_type.params {
		by_ptr := index < len(by_pointer) && by_pointer[index]
		err = plan_argument(store, param_id, index, by_ptr, convention, config, &registers, &params)
		if err != .None { return {}, err }
	}
	if split_results {
		for _ in 0 ..< len(proc_type.results) - 1 {
			if !push(&params, Abi_Param{source = -1, type = .Ptr, attr = .Direct, size = 8, align = 8}) { return {}, .Out_Of_Memory }
		}
	}
	if convention == .Odin {
		if !push(&params, Abi_Param{source = -1, type = .Ptr, attr = .Context, size = 8, align = 8}) { return {}, .Out_Of_Memory }
	}
	return Abi_Plan{convention, proc_type.variadic, params[:], results[:]}, .None
}

@(private = "file")
push :: proc(list: ^[dynamic]Abi_Param, param: Abi_Param) -> bool {
	_, alloc_err := append(list, param)
	return alloc_err == nil
}

// tuple_of appends a temporary tuple type; the caller pops it.
@(private = "file")
tuple_of :: proc(store: ^Store, members: []Type_Id) -> Type_Id {
	fields := make([]Type_Field, len(members), context.temp_allocator)
	for member, index in members { fields[index] = Type_Field{"", member} }
	append(&store.types, Type{kind = .Tuple, fields = fields})
	return Type_Id(len(store.types) - 1)
}

@(private = "file")
plan_error :: proc(err: Layout_Error) -> Plan_Error {
	switch err {
	case .None:
		return .None
	case .Invalid_Type:
		return .Invalid_Type
	case .Incomplete_Type:
		return .Incomplete_Type
	case .Recursive_Value:
		return .Recursive_Value
	case .Poison:
		return .Poison
	}
	return .Invalid_Type
}

@(private = "file")
plan_argument :: proc(
	store: ^Store,
	param_id: Type_Id,
	source: int,
	by_ptr: bool,
	convention: Abi_Convention,
	config: Layout_Config,
	registers: ^Registers,
	params: ^[dynamic]Abi_Param,
) -> Plan_Error {
	id := resolve_named(store, param_id)
	classification, class_err := classify(store, id, config)
	if class_err != .None { return plan_error(class_err) }
	size, alignment := layout_internal(store, id, config, 0)
	t := get(store, id)

	needed_integer, needed_sse := 0, 0
	for class in classification.classes[:classification.count] {
		#partial switch class {
		case .Integer:
			needed_integer += 1
		case .SSE, .SSE_Up:
			needed_sse += 1
		}
	}
	registers.integer -= needed_integer
	registers.sse -= needed_sse
	fits := registers.integer >= 0 && registers.sse >= 0
	registers.integer = max(registers.integer, 0)
	registers.sse = max(registers.sse, 0)
	ran_out_of_regs := !fits && lowered_is_aggregate(store, id, config)

	by_value := Abi_Param{i32(source), .Ptr, .By_Value, .None, u32(size), u16(max(8, alignment))}
	indirect := Abi_Param{i32(source), .Ptr, .Indirect, .None, u32(size), u16(alignment)}
	first_class := classification.classes[0] if classification.count > 0 else Reg_Class.No_Class

	if by_ptr {
		if !push(params, indirect) { return .Out_Of_Memory }
		return .None
	}
	switch {
	case classification.count > 2 && first_class == .SSE:
		if !push(params, by_value) { return .Out_Of_Memory }
	case is_register_type(t, size):
		run := register_pieces(t, size)
		return push_pieces(params, source, run, extension_for(store, id, size))
	case ran_out_of_regs:
		if !push(params, by_value) { return .Out_Of_Memory }
	case first_class == .Memory || is_x87(first_class):
		if !push(params, indirect if convention != .C else by_value) { return .Out_Of_Memory }
	case:
		run, ok := direct_pieces(store, id, classification, size, config)
		if !ok { return .Unsupported_Return }
		return push_pieces(params, source, run, extension_for(store, id, size))
	}
	return .None
}

// plan_result classifies a return value; known_source is false for the last
// value of a multiple-result return, which the official compiler classifies
// from the lowered type and never extends.
@(private = "file")
plan_result :: proc(
	store: ^Store,
	result_id: Type_Id,
	known_source: bool,
	config: Layout_Config,
	params: ^[dynamic]Abi_Param,
	results: ^[dynamic]Abi_Result,
) -> Plan_Error {
	id := resolve_named(store, result_id)
	classification, class_err := classify(store, id, config, known_source)
	if class_err != .None { return plan_error(class_err) }
	size, alignment := layout_internal(store, id, config, 0)
	t := get(store, id)
	if classification.count == 0 { return .None }

	run: Piece_Run
	first_class := classification.classes[0]
	if classification.count > 2 && first_class == .SSE && t.kind != .Simd_Vector {
		first_class = .Memory
	}
	switch {
	case is_register_type(t, size):
		run = register_pieces(t, size)
	case first_class == .Memory:
		sret := Abi_Param{-1, .Ptr, .Struct_Return, .None, u32(size), u16(alignment)}
		if !push(params, sret) { return .Out_Of_Memory }
		return .None
	case:
		ok: bool
		run, ok = direct_pieces(store, id, classification, size, config)
		if !ok { return .Unsupported_Return }
	}
	if run.count > 2 { return .Unsupported_Return }
	ext := Abi_Extension.None
	if known_source { ext = extension_for(store, id, size) }
	for piece in run.pieces[:run.count] {
		if _, alloc_err := append(results, Abi_Result{piece.type, ext, piece.size}); alloc_err != nil { return .Out_Of_Memory }
	}
	return .None
}

@(private = "file")
push_pieces :: proc(params: ^[dynamic]Abi_Param, source: int, pieces: Piece_Run, ext: Abi_Extension) -> Plan_Error {
	run := pieces
	for piece in run.pieces[:run.count] {
		if !push(params, Abi_Param{i32(source), piece.type, .Direct, ext, piece.size, piece.align}) { return .Out_Of_Memory }
	}
	return .None
}

// is_register_type mirrors the official is_register: scalars LLVM passes as a
// single value (floats, pointers and 128-bit integers).
@(private = "file")
is_register_type :: proc(t: ^Type, size: i64) -> bool {
	#partial switch t.kind {
	case .Float, .Pointer, .Multi_Pointer, .Raw_Pointer, .CString, .CString16, .Procedure:
		return size > 0
	case .Integer:
		return size >= 16
	}
	return false
}

@(private = "file")
register_pieces :: proc(t: ^Type, size: i64) -> (run: Piece_Run) {
	#partial switch t.kind {
	case .Float:
		run.pieces[0] = Piece_Info{float_piece(size), u32(size), 8}
		run.count = 1
	case .Integer:
		run.pieces[0] = Piece_Info{.I64, 8, 16}
		run.pieces[1] = Piece_Info{.I64, 8, 8}
		run.count = 2
	case:
		run.pieces[0] = Piece_Info{.Ptr, 8, 8}
		run.count = 1
	}
	return
}

@(private = "file")
float_piece :: proc(bytes: i64) -> Abi_Piece {
	switch bytes {
	case 2:
		return .F16
	case 4:
		return .F32
	}
	return .F64
}

@(private = "file")
integer_piece :: proc(bytes: i64) -> Abi_Piece {
	switch {
	case bytes <= 1:
		return .I8
	case bytes == 2:
		return .I16
	case bytes <= 4:
		return .I32
	}
	return .I64
}

// direct_pieces turns eightbyte classes into register pieces (the official
// llreg), with the {ptr, i64} fast path for strings, slices and alike.
@(private = "file")
direct_pieces :: proc(store: ^Store, id: Type_Id, classification: Classification, size: i64, config: Layout_Config) -> (run: Piece_Run, ok: bool) {
	if is_slice_like(store, id, size, config) {
		run.pieces[0] = Piece_Info{.Ptr, 8, 8}
		run.pieces[1] = Piece_Info{.I64, 8, 8}
		run.count = 2
		return run, true
	}
	remaining := size
	index := 0
	count := int(classification.count)
	for index < count {
		eightbyte_bytes := size - i64(index) * 8
		switch classification.classes[index] {
		case .Integer:
			bytes := min(remaining, 8, eightbyte_bytes)
			add_piece(&run, Piece_Info{integer_piece(bytes), u32(bytes), 8})
			remaining -= min(remaining, 8)
			index += 1
		case .SSE:
			shape := classification.shapes[index]
			element := i64(shape.element_bytes)
			if !shape.vector {
				add_piece(&run, Piece_Info{float_piece(element), u32(min(element, eightbyte_bytes)), 8})
				remaining -= element
				index += 1
				continue
			}
			vector_eightbytes := 1
			for index + vector_eightbytes < count && classification.classes[index + vector_eightbytes] == .SSE_Up {
				vector_eightbytes += 1
			}
			lanes := i64(vector_eightbytes) * (8 / element)
			if lanes * element > remaining { lanes = remaining / element }
			if lanes == 0 { lanes = 1 }
			bytes := min(lanes * element, size - i64(index) * 8)
			remaining -= next_power_of_two(bytes)
			for chunk_bytes := bytes; chunk_bytes > 0; chunk_bytes -= 16 {
				chunk := min(chunk_bytes, 16)
				if chunk > 8 {
					add_piece(&run, Piece_Info{.V128, u32(chunk), 16})
				} else {
					add_piece(&run, Piece_Info{.F64, u32(chunk), 8})
				}
			}
			index += vector_eightbytes
		case .No_Class, .SSE_Up, .X87, .X87_Up, .Complex_X87, .Memory:
			return {}, false
		}
	}
	return run, true
}

@(private = "file")
add_piece :: proc(run: ^Piece_Run, piece: Piece_Info) {
	run.pieces[run.count] = piece
	run.count += 1
}

// is_slice_like is the official is_llvm_type_slice_like on the lowered type:
// exactly a pointer followed by an 8-byte integer.
@(private = "file")
is_slice_like :: proc(store: ^Store, id: Type_Id, size: i64, config: Layout_Config) -> bool {
	t := get(store, id)
	#partial switch t.kind {
	case .String, .String16, .Slice, .Any, .Soa_Pointer:
		return true
	case .Struct:
		if t.raw_union || len(t.fields) != 2 || size != 16 { return false }
		first := get(store, resolve_named(store, t.fields[0].type)).kind
		pointer_first := first == .Raw_Pointer || is_pointer_like(store, t.fields[0].type)
		return pointer_first && lowered_integer_bytes(store, t.fields[1].type, config) == 8 && field_offset_internal(store, id, 1, config) == 8
	}
	return false
}

// lowered_integer_bytes is the size of a type that LLVM lowers to an integer, else 0.
@(private = "file")
lowered_integer_bytes :: proc(store: ^Store, id: Type_Id, config: Layout_Config) -> i64 {
	root := resolve_named(store, id)
	#partial switch get(store, root).kind {
	case .Bool, .Integer, .Rune, .Type_Id, .Enum, .Bit_Set, .Bit_Field:
		size, _ := layout_internal(store, root, config, 0)
		return size
	}
	return 0
}

// extension_for is lb_integer_extension_attribute: integer-like source types
// narrower than 4 bytes are extended by signedness, booleans by zero. A bit_set
// is integer-like but never unsigned in the official compiler, so it is sign
// extended.
@(private = "file")
extension_for :: proc(store: ^Store, id: Type_Id, size: i64) -> Abi_Extension {
	if size >= 4 { return .None }
	t := get(store, id)
	#partial switch t.kind {
	case .Bool:
		return .Zero
	case .Integer:
		return .Sign if t.signed else .Zero
	case .Enum:
		backing := get(store, resolve_named(store, t.backing))
		if backing.kind == .Integer && backing.signed { return .Sign }
		return .Zero
	case .Bit_Set:
		return .Sign
	}
	return .None
}

// lowered_is_aggregate mirrors the official is_aggregate on the lowered LLVM
// type: structs and arrays, except a single-member wrapper of a small scalar.
@(private = "file")
lowered_is_aggregate :: proc(store: ^Store, type_id: Type_Id, config: Layout_Config) -> bool {
	id := resolve_named(store, type_id)
	t := get(store, id)
	size, alignment := layout_internal(store, id, config, 0)
	#partial switch t.kind {
	case .Struct:
		if t.raw_union {
			filler := clamp(alignment, 1, 8)
			length := size / filler if size % filler == 0 else size
			return size > 8 || length != 1
		}
		member_count, sole := struct_lowered_members(store, id, config)
		if member_count != 1 || sole == TYPE_NONE { return true }
		return wrapped_member_is_aggregate(store, sole, true, config)
	case .Tuple:
		if len(t.fields) == 1 { return lowered_is_aggregate(store, t.fields[0].type, config) }
		return true
	case .Array, .Enumerated_Array:
		if t.count == 1 { return wrapped_member_is_aggregate(store, t.elem, false, config) }
		return true
	case .Matrix:
		element_size, _ := layout_internal(store, t.elem, config, 0)
		if size == element_size { return wrapped_member_is_aggregate(store, t.elem, false, config) }
		return true
	case .Union:
		if len(t.variants) == 0 { return true }
		if t.union_form == .Maybe_Pointer { return wrapped_member_is_aggregate(store, t.variants[0], false, config) }
		return true
	case .String, .String16, .Slice, .Any, .Dynamic_Array, .Map, .Complex, .Quaternion, .Soa_Pointer, .Fixed_Capacity_Array:
		return true
	}
	return false
}

@(private = "file")
wrapped_member_is_aggregate :: proc(store: ^Store, member: Type_Id, vector_wraps: bool, config: Layout_Config) -> bool {
	id := resolve_named(store, member)
	if vector_wraps && get(store, id).kind == .Simd_Vector { return true }
	size, _ := layout_internal(store, id, config, 0)
	return size > 8 || lowered_is_aggregate(store, id, config)
}

// struct_lowered_members counts the members of the lowered record: fields plus
// the explicit padding fillers; sole is the field when that is the only member.
@(private = "file")
struct_lowered_members :: proc(store: ^Store, id: Type_Id, config: Layout_Config) -> (count: int, sole: Type_Id) {
	t := get(store, id)
	size, _ := layout_internal(store, id, config, 0)
	previous_end := i64(0)
	for field, index in t.fields {
		start := field_offset_internal(store, id, index, config)
		if start > previous_end { count += 1; sole = TYPE_NONE }
		count += 1
		sole = field.type
		field_size, _ := layout_internal(store, field.type, config, 0)
		previous_end = start + field_size
	}
	if size > previous_end { count += 1; sole = TYPE_NONE }
	if count != 1 { sole = TYPE_NONE }
	return
}
