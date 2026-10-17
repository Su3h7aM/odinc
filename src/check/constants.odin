package check

import "base:runtime"
import "core:math/big"
import "core:mem"
import "core:strconv"
import "core:strings"
import "oc:types"

Constant_Pool_Error :: enum u8 {
	None,
	Uninitialized,
	Handle_Limit,
	Invalid_Float_Width,
	Invalid_Component,
	Invalid_Operand,
	Unsupported_Operator,
	Division_By_Zero,
	Negative_Shift,
	Shift_Too_Large,
	Not_Representable,
	Unsupported_Constant_Op,
	Missing_Type_Store,
}
Constant_Error :: union #shared_nil {
	Constant_Pool_Error,
	runtime.Allocator_Error,
	big.Error,
}

// Owns interned integer/rational limbs, key bytes and table storage in one arena.
// Borrowed constants returned by constant_pool_get remain valid until destruction.
// The phase coordinator keeps this pool alive while its Checked_Program view is used.
Constant_Pool :: struct {
	arena:     mem.Dynamic_Arena,
	allocator: mem.Allocator,
	values:    [dynamic]Constant,
	keys:      map[string]Const_Id,
}

@(require_results)
constant_pool_init :: proc(pool: ^Constant_Pool, allocator: mem.Allocator) -> (err: runtime.Allocator_Error) {
	assert(
		pool != nil && len(pool.values) == 0 && pool.allocator.procedure == nil && pool.arena.block_allocator.procedure == nil && allocator.procedure != nil,
	)
	mem.dynamic_arena_init(&pool.arena, block_allocator = allocator, array_allocator = allocator)
	pool.allocator = mem.dynamic_arena_allocator(&pool.arena)
	pool.values.allocator = pool.allocator
	pool.keys = make(map[string]Const_Id, pool.allocator)
	defer if err != nil { constant_pool_destroy(pool) }
	append(&pool.values, Constant{}) or_return
	return nil
}

constant_pool_destroy :: proc(pool: ^Constant_Pool) {
	if pool == nil { return }
	delete(pool.keys)
	delete(pool.values)
	mem.dynamic_arena_destroy(&pool.arena)
	pool^ = {}
}

// Interns an immutable copy. The source integer is borrowed and may be changed afterward.
@(require_results)
constant_pool_intern_integer :: proc(pool: ^Constant_Pool, value: ^big.Int, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	if value == nil { return 0, big.Error.Invalid_Pointer }
	key, key_error := constant_pool_integer_key(pool, type, value)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	stored: big.Int
	big.int_copy(&stored, value, allocator = pool.allocator) or_return
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = stored}) or_return
	pool.keys[key] = id
	return id, nil
}

// Interns a reduced rational copy. Numerator and denominator storage is arena-owned.
@(require_results)
constant_pool_intern_rational :: proc(pool: ^Constant_Pool, value: ^big.Rat, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	if value == nil { return 0, big.Error.Invalid_Pointer }
	denominator_is_zero, denominator_error := big.is_zero(&value.b, allocator = pool.allocator)
	if denominator_error != nil { return 0, denominator_error }
	if denominator_is_zero { return 0, big.Error.Division_by_Zero }
	stored: big.Rat
	big.rat_copy(&stored, value, allocator = pool.allocator) or_return
	key, key_error := constant_pool_rational_key(pool, type, &stored)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = stored}) or_return
	pool.keys[key] = id
	return id, nil
}

constant_pool_get :: proc(pool: ^Constant_Pool, id: Const_Id) -> ^Constant {
	if !constant_pool_ready(pool) || id == 0 || u64(id) >= u64(len(pool.values)) { return nil }
	return &pool.values[id]
}

@(require_results)
constant_pool_intern_bool :: proc(pool: ^Constant_Pool, value: bool, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	key := constant_pool_simple_key(pool, "b:", type, "true" if value else "false") or_return
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = value}) or_return
	pool.keys[key] = id
	return id, nil
}

@(require_results)
constant_pool_intern_nil :: proc(pool: ^Constant_Pool, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	key := constant_pool_simple_key(pool, "n:", type, "nil") or_return
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = Nil_Value{}}) or_return
	pool.keys[key] = id
	return id, nil
}

// Aggregates are not deduplicated: each composite literal is its own immutable value.
@(require_results)
constant_pool_intern_aggregate :: proc(pool: ^Constant_Pool, type: types.Type_Id, elements: []Const_Id) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	stored := make([]Const_Id, len(elements), pool.allocator) or_return
	copy(stored, elements)
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = Aggregate_Value{elements = stored}}) or_return
	return id, nil
}

// Interns a borrowed UTF-8 string as an arena-owned immutable copy.
@(require_results)
constant_pool_intern_string :: proc(pool: ^Constant_Pool, value: string, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	key, key_error := constant_pool_string_key(pool, "s:", type, value)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	stored, clone_error := strings.clone(value, pool.allocator)
	if clone_error != nil { return 0, clone_error }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = stored}) or_return
	pool.keys[key] = id
	return id, nil
}

// Interns a borrowed UTF-16 string as an arena-owned immutable copy.
@(require_results)
constant_pool_intern_string16 :: proc(pool: ^Constant_Pool, value: []u16, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	key, key_error := constant_pool_string16_key(pool, type, value)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	stored := make([]u16, len(value), pool.allocator)
	copy(stored, value)
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = stored}) or_return
	pool.keys[key] = id
	return id, nil
}

@(private = "file")
constant_pool_ready :: proc(pool: ^Constant_Pool) -> bool {
	return pool != nil && pool.arena.block_allocator.procedure != nil && len(pool.values) > 0
}

@(private = "file")
constant_pool_integer_key :: proc(pool: ^Constant_Pool, type: types.Type_Id, value: ^big.Int) -> (key: string, err: Constant_Error) {
	text, conversion_error := big.int_to_string(value, 10, allocator = pool.allocator)
	if conversion_error != nil { return "", conversion_error }
	type_buffer: [11]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	segments := [4]string{"i:", type_text, ":", text}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

@(private = "file")
constant_pool_rational_key :: proc(pool: ^Constant_Pool, type: types.Type_Id, value: ^big.Rat) -> (key: string, err: Constant_Error) {
	numerator, conversion_error := big.int_to_string(&value.a, 10, allocator = pool.allocator)
	if conversion_error != nil { return "", conversion_error }
	denominator: string
	denominator, conversion_error = big.int_to_string(&value.b, 10, allocator = pool.allocator)
	if conversion_error != nil { return "", conversion_error }
	type_buffer: [11]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	segments := [6]string{"r:", type_text, ":", numerator, "/", denominator}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

// Interns an IEEE float bit pattern. Width is part of the key; signed zero and NaN payloads remain distinct.
@(require_results)
constant_pool_intern_float :: proc(pool: ^Constant_Pool, value: Float_Value, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	if value.width != 16 && value.width != 32 && value.width != 64 { return 0, Constant_Pool_Error.Invalid_Float_Width }
	if value.width == 16 && value.bits > u64(max(u16)) || value.width == 32 && value.bits > u64(max(u32)) {
		return 0, Constant_Pool_Error.Invalid_Float_Width
	}
	key, key_error := constant_pool_float_key(pool, type, value)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = value}) or_return
	pool.keys[key] = id
	return id, nil
}

// Interns component handles in real/imaginary order.
@(require_results)
constant_pool_intern_complex :: proc(pool: ^Constant_Pool, value: Complex_Value, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	for component in value {
		if constant_pool_get(pool, component) == nil { return 0, Constant_Pool_Error.Invalid_Component }
	}
	key, key_error := constant_pool_complex_key(pool, type, value)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = value}) or_return
	pool.keys[key] = id
	return id, nil
}

// Interns quaternion components in real/i/j/k order.
@(require_results)
constant_pool_intern_quaternion :: proc(pool: ^Constant_Pool, value: Quaternion_Value, type: types.Type_Id = 0) -> (id: Const_Id, err: Constant_Error) {
	if !constant_pool_ready(pool) { return 0, Constant_Pool_Error.Uninitialized }
	for component in value {
		if constant_pool_get(pool, component) == nil { return 0, Constant_Pool_Error.Invalid_Component }
	}
	key, key_error := constant_pool_quaternion_key(pool, type, value)
	if key_error != nil { return 0, key_error }
	if existing, found := pool.keys[key]; found { return existing, nil }
	if u64(len(pool.values)) > u64(max(u32)) { return 0, Constant_Pool_Error.Handle_Limit }
	id = Const_Id(len(pool.values))
	append(&pool.values, Constant{type = type, value = value}) or_return
	pool.keys[key] = id
	return id, nil
}

@(private = "file")
constant_pool_float_key :: proc(pool: ^Constant_Pool, type: types.Type_Id, value: Float_Value) -> (key: string, err: Constant_Error) {
	type_buffer: [11]byte
	width_buffer: [3]byte
	bits_buffer: [16]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	width_text := strconv.write_bits(width_buffer[:], u64(value.width), 10, false, 8, strconv.digits, {})
	bits_text := strconv.write_bits(bits_buffer[:], value.bits, 16, false, 64, strconv.digits, {})
	segments := [6]string{"f:", type_text, ":", width_text, ":", bits_text}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

@(private = "file")
constant_pool_complex_key :: proc(pool: ^Constant_Pool, type: types.Type_Id, value: Complex_Value) -> (key: string, err: Constant_Error) {
	type_buffer: [11]byte
	real_length_buffer, imaginary_length_buffer: [20]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	real_text, key_error := constant_pool_numeric_key(pool, value[0])
	if key_error != nil { return "", key_error }
	imaginary_text: string
	imaginary_text, key_error = constant_pool_numeric_key(pool, value[1])
	if key_error != nil { return "", key_error }
	real_length := strconv.write_bits(real_length_buffer[:], u64(len(real_text)), 10, false, 64, strconv.digits, {})
	imaginary_length := strconv.write_bits(imaginary_length_buffer[:], u64(len(imaginary_text)), 10, false, 64, strconv.digits, {})
	segments := [9]string{"c:", type_text, ":", real_length, "#", real_text, imaginary_length, "#", imaginary_text}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

@(private = "file")
constant_pool_quaternion_key :: proc(pool: ^Constant_Pool, type: types.Type_Id, value: Quaternion_Value) -> (key: string, err: Constant_Error) {
	type_buffer: [11]byte
	component_length_buffer: [4][20]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	component_text: [4]string
	component_length: [4]string
	for i in 0 ..< 4 {
		component_text[i], err = constant_pool_numeric_key(pool, value[i])
		if err != nil { return "", err }
		component_length[i] = strconv.write_bits(component_length_buffer[i][:], u64(len(component_text[i])), 10, false, 64, strconv.digits, {})
	}
	segments := [15]string {
		"q:",
		type_text,
		":",
		component_length[0],
		"#",
		component_text[0],
		component_length[1],
		"#",
		component_text[1],
		component_length[2],
		"#",
		component_text[2],
		component_length[3],
		"#",
		component_text[3],
	}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

@(private = "file")
constant_pool_numeric_key :: proc(pool: ^Constant_Pool, id: Const_Id) -> (key: string, err: Constant_Error) {
	entry := constant_pool_get(pool, id)
	if entry == nil { return "", Constant_Pool_Error.Invalid_Component }
	#partial switch &value in entry.value {
	case big.Int:
		return constant_pool_integer_key(pool, entry.type, &value)
	case big.Rat:
		return constant_pool_rational_key(pool, entry.type, &value)
	case Float_Value:
		return constant_pool_float_key(pool, entry.type, value)
	}
	return "", Constant_Pool_Error.Invalid_Component
}

@(private = "file")
constant_pool_simple_key :: proc(pool: ^Constant_Pool, prefix: string, type: types.Type_Id, value: string) -> (key: string, err: Constant_Error) {
	type_buffer: [11]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	segments := [4]string{prefix, type_text, ":", value}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

@(private = "file")
constant_pool_string_key :: proc(pool: ^Constant_Pool, prefix: string, type: types.Type_Id, value: string) -> (key: string, err: Constant_Error) {
	type_buffer: [11]byte
	length_buffer: [20]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	length_text := strconv.write_bits(length_buffer[:], u64(len(value)), 10, false, 64, strconv.digits, {})
	segments := [6]string{prefix, type_text, ":", length_text, "#", value}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}

@(private = "file")
constant_pool_string16_key :: proc(pool: ^Constant_Pool, type: types.Type_Id, value: []u16) -> (key: string, err: Constant_Error) {
	type_buffer: [11]byte
	length_buffer: [20]byte
	type_text := strconv.write_bits(type_buffer[:], u64(type), 10, false, 32, strconv.digits, {})
	length_text := strconv.write_bits(length_buffer[:], u64(len(value)), 10, false, 64, strconv.digits, {})
	segments := make([dynamic]string, pool.allocator)
	defer delete(segments)
	append(&segments, "s16:", type_text, ":", length_text, "#") or_return
	for unit in value {
		buffer: [4]byte
		text := strconv.write_bits(buffer[:], u64(unit), 16, false, 16, strconv.digits, {})
		append(&segments, text) or_return
	}
	return strings.concatenate(segments[:], allocator = pool.allocator)
}
