package types

import "base:runtime"

// Type_Id is a stable index into Store.types. Zero denotes no type; TYPE_POISON
// is the reserved error-recovery type whose layout is always an error.
Type_Id :: distinct u32
TYPE_NONE :: Type_Id(0)
TYPE_POISON :: Type_Id(1)

// Canonical untyped ids are fixed immediately after TYPE_POISON.
TYPE_UNTYPED_BOOL :: Type_Id(2)
TYPE_UNTYPED_INTEGER :: Type_Id(3)
TYPE_UNTYPED_RUNE :: Type_Id(4)
TYPE_UNTYPED_FLOAT :: Type_Id(5)
TYPE_UNTYPED_COMPLEX :: Type_Id(6)
TYPE_UNTYPED_QUATERNION :: Type_Id(7)
TYPE_UNTYPED_STRING :: Type_Id(8)
TYPE_UNTYPED_NIL :: Type_Id(9)

Kind :: enum u8 {
	Invalid,
	Bool,
	Integer,
	Float,
	Rune,
	Complex,
	Quaternion,
	String,
	String16,
	CString,
	CString16,
	Raw_Pointer,
	Pointer,
	Multi_Pointer,
	Slice,
	Array,
	Enumerated_Array,
	Dynamic_Array,
	Fixed_Capacity_Array,
	Map,
	Struct,
	Union,
	Enum,
	Bit_Set,
	Bit_Field,
	Procedure,
	Tuple,
	Any,
	Type_Id,
	Matrix,
	Simd_Vector,
	Soa_Pointer,
	Named,
	Poison,
	Untyped_Bool,
	Untyped_Integer,
	Untyped_Rune,
	Untyped_Float,
	Untyped_Complex,
	Untyped_Quaternion,
	Untyped_String,
	Untyped_Nil,
}

Endian :: enum u8 {
	Native,
	Little,
	Big,
}

Calling_Convention :: enum u8 {
	Odin,
	Contextless,
	C,
	Stdcall,
	Fastcall,
	Win64,
	SysV,
	Preserve_None,
	Preserve_Most,
	Preserve_All,
	Inline_Asm,
}
Union_Form :: enum u8 {
	Tagged,
	Maybe_Pointer,
	Shared_Nil,
	No_Nil,
}
Soa_Kind :: enum u8 {
	None,
	Fixed,
	Slice,
	Dynamic,
}
Layout_State :: enum u8 {
	Unlaid_Out,
	In_Progress,
	Done,
}
Layout_Error :: enum u8 {
	None,
	Invalid_Type,
	Incomplete_Type,
	Recursive_Value,
	Poison,
}

Type_Field :: struct {
	name: string,
	type: Type_Id,
}

Union_Layout :: struct {
	size, alignment, variant_block_size, tag_size: i64,
}

// Type is an immutable canonical descriptor. Element, index, and fields refer to
// types already present in the store; field, variant, parameter, and result
// slices are borrowed and must remain unchanged while the descriptor is stored.
Type :: struct {
	kind:                                           Kind,
	name:                                           string,
	elem, index:                                    Type_Id,
	fields:                                         []Type_Field,
	bit_sizes:                                      []u8,
	variants:                                       []Type_Id,
	params, results:                                []Type_Id,
	count, lower_bound, upper_bound:                i64,
	backing:                                        Type_Id,
	endianness:                                     Endian,
	signed, variadic, c_vararg:                     bool,
	optional_result:                                bool,
	diverging:                                      bool,
	convention:                                     Calling_Convention,
	union_form:                                     Union_Form,
	soa:                                            Soa_Kind,
	custom_align, min_field_align, max_field_align: i64,
	row_major:                                      bool,
	packed, raw_union:                              bool,
	sparse:                                         bool,
	is_nominal, is_complete:                        bool,
	layout_state:                                   Layout_State,
}

// Layout_Config describes target ABI parameters used by the fork's layout rules.
// Its zero value is not a valid target; DEFAULT_LAYOUT is Linux x86-64.
Layout_Config :: struct {
	int_size, ptr_size, max_align, max_simd_align: i64,
}
DEFAULT_LAYOUT :: Layout_Config{8, 8, 16, 512}

// Each descriptor is allocated once, so a pointer from get stays valid until destroy, as official alloc_type does
// (Odin/src/types.cpp:1061-1068). Type_Id stays the handle.
Store :: struct {
	types:     [dynamic]^Type,
	allocator: runtime.Allocator,
}

init :: proc() -> Store {
	store := Store {
		allocator = context.allocator,
	}
	reserve_slots(&store)
	return store
}

reserve_slots :: proc(store: ^Store) {
	if len(store.types) == 0 {
		append_type(store, Type{})
		append_type(store, Type{kind = .Poison})
		append_type(store, Type{kind = .Untyped_Bool})
		append_type(store, Type{kind = .Untyped_Integer})
		append_type(store, Type{kind = .Untyped_Rune})
		append_type(store, Type{kind = .Untyped_Float})
		append_type(store, Type{kind = .Untyped_Complex})
		append_type(store, Type{kind = .Untyped_Quaternion})
		append_type(store, Type{kind = .Untyped_String})
		append_type(store, Type{kind = .Untyped_Nil})
	}
}

destroy :: proc(store: ^Store) {
	for descriptor in store.types { _ = free(descriptor, store.allocator) }
	delete(store.types)
	store^ = Store{}
}

append_type :: proc(store: ^Store, descriptor: Type) -> Type_Id {
	allocated, allocation_error := new(Type, store.allocator)
	if allocation_error != nil { panic("type store is out of memory") }
	allocated^ = descriptor
	append(&store.types, allocated)
	return Type_Id(len(store.types) - 1)
}

pop_type :: proc(store: ^Store) {
	_ = free(pop(&store.types), store.allocator)
}

// Intern returns a deterministic id, reusing a structurally identical descriptor.
intern :: proc(store: ^Store, descriptor: Type) -> Type_Id {
	assert(descriptor.kind != .Invalid)
	reserve_slots(store)
	for i in 0 ..< len(store.types) {
		if descriptors_equal(store.types[i]^, descriptor) { return Type_Id(i) }
	}
	return append_type(store, descriptor)
}

// sized_integer interns the basic integer of `count` bytes under its official name, so it equals the builtin.
sized_integer :: proc(store: ^Store, count: i64, signed: bool) -> Type_Id {
	name := ""
	switch count {
	case 1:
		name = "i8" if signed else "u8"
	case 2:
		name = "i16" if signed else "u16"
	case 4:
		name = "i32" if signed else "u32"
	case 8:
		name = "i64" if signed else "u64"
	case 16:
		name = "i128" if signed else "u128"
	}
	return intern(store, Type{kind = .Integer, name = name, count = count, signed = signed})
}

get :: proc(store: ^Store, id: Type_Id) -> ^Type {
	index := int(id)
	assert(id != TYPE_NONE && index >= 1 && index < len(store.types))
	return store.types[index]
}

is_untyped :: proc(store: ^Store, id: Type_Id) -> bool {
	if store == nil || id == TYPE_NONE || u64(id) >= u64(len(store.types)) { return false }
	type_id := id
	for _ in 0 ..< len(store.types) {
		descriptor := get(store, type_id)
		#partial switch descriptor.kind {
		case .Named:
			type_id = descriptor.elem
			if type_id == TYPE_NONE || u64(type_id) >= u64(len(store.types)) { return false }
		case .Untyped_Bool, .Untyped_Integer, .Untyped_Rune, .Untyped_Float, .Untyped_Complex, .Untyped_Quaternion, .Untyped_String, .Untyped_Nil:
			return true
		case:
			return false
		}
	}
	return false
}

default_type_of_untyped :: proc(store: ^Store, id: Type_Id) -> Type_Id {
	if !is_untyped(store, id) { return id }
	type_id := id
	descriptor := get(store, type_id)
	for _ in 0 ..< len(store.types) {
		if descriptor.kind != .Named { break }
		type_id = descriptor.elem
		if type_id == TYPE_NONE || u64(type_id) >= u64(len(store.types)) { return type_id }
		descriptor = get(store, type_id)
	}
	#partial switch descriptor.kind {
	case .Untyped_Bool:
		return intern(store, Type{kind = .Bool})
	case .Untyped_Integer:
		return intern(store, Type{kind = .Integer, name = "int", count = DEFAULT_LAYOUT.int_size, signed = true})
	case .Untyped_Rune:
		return intern(store, Type{kind = .Rune, name = "rune", count = 4, signed = true})
	case .Untyped_Float:
		return intern(store, Type{kind = .Float, count = 8})
	case .Untyped_Complex:
		return intern(store, Type{kind = .Complex, count = 16})
	case .Untyped_Quaternion:
		return intern(store, Type{kind = .Quaternion, count = 32})
	case .Untyped_String:
		return intern(store, Type{kind = .String})
	case .Untyped_Nil:
		return type_id
	}
	return type_id
}

// reserve_nominal assigns an identity before a nominal type's base or members are known.
reserve_nominal :: proc(store: ^Store, kind: Kind, name: string) -> Type_Id {
	assert(kind == .Named || kind == .Struct || kind == .Union || kind == .Enum || kind == .Procedure)
	reserve_slots(store)
	return append_type(store, Type{kind = kind, name = name, is_nominal = true})
}

// complete_nominal fills a reserved nominal, including a named type's base, without changing its id.
complete_nominal :: proc(store: ^Store, id: Type_Id, descriptor: Type) {
	reserved := get(store, id)
	assert(reserved.is_nominal && !reserved.is_complete)
	assert(reserved.kind == descriptor.kind && reserved.name == descriptor.name)
	completed := descriptor
	completed.is_nominal = true
	completed.is_complete = true
	completed.layout_state = .Unlaid_Out
	reserved^ = completed
}

descriptors_equal :: proc(a, b: Type) -> bool {
	if a.kind != b.kind ||
	   a.name != b.name ||
	   a.elem != b.elem ||
	   a.index != b.index ||
	   a.count != b.count ||
	   a.lower_bound != b.lower_bound ||
	   a.upper_bound != b.upper_bound ||
	   a.backing != b.backing ||
	   a.endianness != b.endianness ||
	   a.signed != b.signed ||
	   a.variadic != b.variadic ||
	   a.c_vararg != b.c_vararg ||
	   a.optional_result != b.optional_result ||
	   a.diverging != b.diverging ||
	   a.convention != b.convention ||
	   a.union_form != b.union_form ||
	   a.soa != b.soa ||
	   a.custom_align != b.custom_align ||
	   a.min_field_align != b.min_field_align ||
	   a.max_field_align != b.max_field_align ||
	   a.row_major != b.row_major ||
	   a.packed != b.packed ||
	   a.raw_union != b.raw_union ||
	   a.is_nominal != b.is_nominal ||
	   a.is_complete != b.is_complete ||
	   len(a.fields) != len(b.fields) ||
	   len(a.bit_sizes) != len(b.bit_sizes) ||
	   len(a.variants) != len(b.variants) {
		return false
	}
	for i in 0 ..< len(a.fields) { if a.fields[i] != b.fields[i] { return false } }
	for i in 0 ..< len(a.bit_sizes) { if a.bit_sizes[i] != b.bit_sizes[i] { return false } }
	for i in 0 ..< len(a.variants) { if a.variants[i] != b.variants[i] { return false } }
	if len(a.params) != len(b.params) || len(a.results) != len(b.results) { return false }
	for i in 0 ..< len(a.params) { if a.params[i] != b.params[i] { return false } }
	for i in 0 ..< len(a.results) { if a.results[i] != b.results[i] { return false } }
	return true
}

layout :: proc(store: ^Store, id: Type_Id, config := DEFAULT_LAYOUT) -> (size, alignment: i64, err: Layout_Error) {
	if id == TYPE_NONE || int(id) >= len(store.types) { return 0, 1, .Invalid_Type }
	err = validate_layout(store, id)
	if err != .None {
		reset_layout_states(store)
		return 0, 1, err
	}
	size, alignment = layout_internal(store, id, config, 0)
	return size, alignment, .None
}

reset_layout_states :: proc(store: ^Store) {
	for i in 1 ..< len(store.types) { store.types[i].layout_state = .Unlaid_Out }
}

validate_layout :: proc(store: ^Store, id: Type_Id) -> Layout_Error {
	if id == TYPE_NONE || int(id) >= len(store.types) { return .Invalid_Type }
	if is_untyped(store, id) { return .Invalid_Type }
	t := get(store, id)
	if t.kind == .Poison { return .Poison }
	if t.layout_state == .Done { return .None }
	if t.layout_state == .In_Progress { return .Recursive_Value }
	if t.is_nominal && !t.is_complete { return .Incomplete_Type }
	t.layout_state = .In_Progress
	err := Layout_Error.None
	#partial switch t.kind {
	case .Array, .Enumerated_Array, .Fixed_Capacity_Array, .Simd_Vector, .Matrix:
		err = validate_layout(store, t.elem)
	case .Struct, .Tuple:
		for field in t.fields { err = validate_layout(store, field.type); if err != .None { break } }
	case .Union:
		for variant in t.variants { err = validate_layout(store, variant); if err != .None { break } }
	case .Enum, .Bit_Field:
		err = validate_layout(store, t.backing)
	case .Named:
		err = validate_layout(store, t.elem)
	case .Bit_Set:
		if t.backing != TYPE_NONE { err = validate_layout(store, t.backing) }
	case:
	}
	if err != .None { return err }
	t.layout_state = .Done
	return .None
}

layout_internal :: proc(store: ^Store, id: Type_Id, config: Layout_Config, depth: int) -> (size, alignment: i64) {
	assert(depth < len(store.types) + 1)
	t := get(store, id)
	ptr, word := config.ptr_size, config.int_size
	switch t.kind {
	case .Invalid, .Poison:
		return 0, 1
	case .Untyped_Bool, .Untyped_Integer, .Untyped_Rune, .Untyped_Float, .Untyped_Complex, .Untyped_Quaternion, .Untyped_String, .Untyped_Nil:
		return 0, 1
	case .Bool:
		byte_size := max(t.count, 1)
		return byte_size, min(byte_size, target_max_align(config))
	case .Integer, .Float, .Rune:
		byte_size := t.count
		if byte_size <= 0 { byte_size = 4 }
		return byte_size, min(byte_size, target_max_align(config))
	case .Complex:
		byte_size := t.count; return byte_size, min(byte_size / 2, target_max_align(config))
	case .Quaternion:
		byte_size := t.count; return byte_size, min(byte_size / 4, target_max_align(config))
	case .String, .String16:
		return 2 * word, word
	case .CString, .CString16, .Raw_Pointer, .Pointer, .Multi_Pointer, .Procedure:
		return ptr, ptr
	case .Slice:
		return 2 * word, word
	case .Dynamic_Array:
		return 3 * word + 2 * ptr, word
	case .Fixed_Capacity_Array:
		es, ea := layout_internal(store, t.elem, config, depth + 1)
		a := max(word, ea)
		return align_up(es * t.count, word) + word, a
	case .Map:
		return 4 * ptr, ptr
	case .Any:
		return 16, 8
	case .Type_Id:
		return 8, 8
	case .Array, .Enumerated_Array:
		es, ea := layout_internal(store, t.elem, config, depth + 1)
		if t.count <= 0 { return 0, ea }
		return align_up(es, ea) * (t.count - 1) + es, ea
	case .Tuple:
		return fields_layout(store, t.fields, false, false, 0, 0, 0, config, depth)
	case .Struct:
		return fields_layout(store, t.fields, t.packed, t.raw_union, t.custom_align, t.min_field_align, t.max_field_align, config, depth)
	case .Union:
		union_info := union_layout_internal(store, t, config, depth)
		return union_info.size, union_info.alignment
	case .Enum, .Bit_Field:
		return layout_internal(store, t.backing, config, depth + 1)
	case .Bit_Set:
		if t.backing != TYPE_NONE { return layout_internal(store, t.backing, config, depth + 1) }
		bits := t.upper_bound - t.lower_bound + 1
		switch {
		case bits <= 8:
			return 1, 1
		case bits <= 16:
			return 2, 2
		case bits <= 32:
			return 4, 4
		case bits <= 64:
			return 8, 8
		case bits <= 128:
			return 16, 16
		case:
			return 8, 8
		}
	case .Simd_Vector:
		es, _ := layout_internal(store, t.elem, config, depth + 1)
		sz := es * t.count
		return sz, clamp(next_power_of_two(sz), 1, config.max_simd_align)
	case .Matrix:
		es, ea := layout_internal(store, t.elem, config, depth + 1)
		stride_count, other_count := t.count, t.upper_bound
		if t.row_major { stride_count, other_count = t.upper_bound, t.count }
		stride := es * stride_count
		return stride * other_count, clamp(stride & -stride, ea, min(16, config.max_simd_align))
	case .Soa_Pointer:
		return 2 * word, word
	case .Named:
		return layout_internal(store, t.elem, config, depth + 1)
	case:
		return ptr, min(ptr, target_max_align(config))
	}
}

union_layout :: proc(store: ^Store, id: Type_Id, config := DEFAULT_LAYOUT) -> (result: Union_Layout, err: Layout_Error) {
	if id == TYPE_NONE || int(id) >= len(store.types) { return {}, .Invalid_Type }
	err = validate_layout(store, id)
	if err != .None { reset_layout_states(store); return {}, err }
	t := get(store, id)
	if t.kind != .Union { return {}, .Invalid_Type }
	return union_layout_internal(store, t, config, 0), .None
}

union_layout_internal :: proc(store: ^Store, t: ^Type, config: Layout_Config, depth: int) -> Union_Layout {
	if len(t.variants) == 0 { return Union_Layout{0, 1, 0, 0} }
	max_size, max_align := i64(0), i64(1)
	for variant in t.variants {
		size, alignment := layout_internal(store, variant, config, depth + 1)
		max_size, max_align = max(max_size, size), max(max_align, alignment)
	}
	if t.custom_align > 0 { max_align = t.custom_align }
	if t.union_form == .Maybe_Pointer {
		return Union_Layout{align_up(max_size, max_align), max_align, max_size, 0}
	}
	tag_size := union_tag_size(len(t.variants), max_align, config.max_align)
	block_size := align_up(max_size, tag_size)
	return Union_Layout{align_up(block_size + tag_size, max_align), max_align, block_size, tag_size}
}

field_offset :: proc(store: ^Store, id: Type_Id, index: int, config := DEFAULT_LAYOUT) -> (offset: i64, err: Layout_Error) {
	if id == TYPE_NONE || int(id) >= len(store.types) { return 0, .Invalid_Type }
	err = validate_layout(store, id)
	if err != .None { reset_layout_states(store); return 0, err }
	return field_offset_internal(store, id, index, config), .None
}

field_offset_internal :: proc(store: ^Store, id: Type_Id, index: int, config: Layout_Config) -> i64 {
	t := get(store, id)
	if t.kind == .Array || t.kind == .Enumerated_Array {
		es, _ := layout_internal(store, t.elem, config, 0)
		assert(index >= 0 && i64(index) < t.count)
		return i64(index) * es
	}
	word, ptr := config.int_size, config.ptr_size
	#partial switch t.kind {
	case .String, .String16:
		assert(index >= 0 && index < 2)
		return i64(index) * word
	case .Any:
		assert(index >= 0 && index < 2)
		return i64(index) * 8
	case .Slice:
		assert(index >= 0 && index < 2)
		return i64(index) * word
	case .Dynamic_Array:
		assert(index >= 0 && index < 4)
		return i64(index) * word
	case .Map:
		assert(index >= 0 && index < 4)
		return i64(index) * ptr
	case:
		break
	}
	fields := t.fields
	assert(index >= 0 && index < len(fields))
	if t.kind == .Struct && t.raw_union { return 0 }
	if t.kind == .Struct && t.packed {
		offset := i64(0)
		for i in 0 ..< index { s, _ := layout_internal(store, fields[i].type, config, 0); offset += s }
		return offset
	}
	offset := i64(0)
	for i in 0 ..< index {
		s, a := layout_internal(store, fields[i].type, config, 0)
		a = max(a, max(t.min_field_align, 1))
		if t.max_field_align != 0 { a = min(a, t.max_field_align) }
		offset = align_up(offset, a) + max(s, 0)
	}
	_, a := layout_internal(store, fields[index].type, config, 0)
	a = max(a, max(t.min_field_align, 1))
	if t.max_field_align != 0 { a = min(a, t.max_field_align) }
	return align_up(offset, a)
}

// The fields of `any` are a data pointer, then a typeid. The checker interns both when it checks an `any` literal, so lookup never appends to the store.
any_field_type :: proc(store: ^Store, index: int) -> (id: Type_Id, found: bool) {
	descriptor := Type {
		kind = .Type_Id,
	}
	if index == 0 { descriptor.kind = .Raw_Pointer }
	for stored, position in store.types {
		if descriptors_equal(stored^, descriptor) { return Type_Id(position), true }
	}
	return TYPE_NONE, false
}

// The type of field index of id; `any` keeps no stored fields, so its two come from any_field_type.
field_type :: proc(store: ^Store, id: Type_Id, index: int) -> (type: Type_Id, found: bool) {
	descriptor := get(store, id)
	if descriptor.kind == .Any { return any_field_type(store, index) }
	if index < 0 || index >= len(descriptor.fields) { return TYPE_NONE, false }
	return descriptor.fields[index].type, true
}

fields_layout :: proc(
	store: ^Store,
	fields: []Type_Field,
	packed, raw_union: bool,
	custom_align, min_field_align, max_field_align: i64,
	config: Layout_Config,
	depth: int,
) -> (
	size, alignment: i64,
) {
	if len(fields) == 0 { return 0, 1 }
	max_size, max_align := i64(0), i64(1)
	for field in fields {
		s, a := layout_internal(store, field.type, config, depth + 1)
		max_size, max_align = max(max_size, s), max(max_align, a)
	}
	if custom_align > 0 {
		field_size := max_size
		if packed { field_size = sum_field_sizes(store, fields, config) }
		return align_up(field_size, custom_align), custom_align
	}
	if packed {
		return sum_field_sizes(store, fields, config), 1
	}
	if raw_union {
		if min_field_align > 0 { max_align = max(max_align, min_field_align) }
		if max_field_align != 0 { max_align = min(max_align, max_field_align) }
		return align_up(max_size, max_align), max_align
	}
	offset := i64(0)
	for field in fields {
		s, a := layout_internal(store, field.type, config, depth + 1)
		a = max(a, max(min_field_align, 1))
		if max_field_align != 0 { a = min(a, max_field_align) }
		offset = align_up(offset, a) + max(s, 0)
	}
	if min_field_align > 0 { max_align = max(max_align, min_field_align) }
	if max_field_align != 0 { max_align = min(max_align, max_field_align) }
	return align_up(offset, max_align), max_align
}

// The bit offset and width of a bit_field's field. Offsets are prefix sums counted from the least significant bit.
bit_field_slot :: proc(store: ^Store, id: Type_Id, index: int) -> (offset, size: u32) {
	descriptor := get(store, id)
	for previous in 0 ..< index { offset += u32(descriptor.bit_sizes[previous]) }
	return offset, u32(descriptor.bit_sizes[index])
}

sum_field_sizes :: proc(store: ^Store, fields: []Type_Field, config: Layout_Config) -> i64 {
	size := i64(0)
	for field in fields { s, _ := layout_internal(store, field.type, config, 0); size += s }
	return size
}

union_tag_size :: proc(variants: int, alignment, max_target_align: i64) -> i64 {
	tag_alignment := i64(1)
	if variants >= 1 << 8 { tag_alignment = 2 }
	if variants >= 1 << 16 { tag_alignment = 4 }
	return min(min(max(tag_alignment, alignment), max_target_align), 8)
}

target_max_align :: proc(config: Layout_Config) -> i64 { return config.max_align }
align_up :: proc(size, alignment: i64) -> i64 { if alignment <= 1 { return size }; return ((size + alignment - 1) / alignment) * alignment }
next_power_of_two :: proc(value: i64) -> i64 { if value <= 1 { return 1 }; result := i64(1); for result < value { result *= 2 }; return result }
clamp :: proc(value, lower, upper: i64) -> i64 { return min(max(value, lower), upper) }
