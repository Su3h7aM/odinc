package main

import "core:slice"

Scalar :: enum u8 {
	U8,
	I8,
	U16,
	I16,
	U32,
	I32,
	U64,
	I64,
	U128,
	I128,
	F16,
	F32,
	F64,
	Ptr,
	Bool,
}

Spec_Kind :: enum u8 {
	Scalar,
	Struct,
	Union,
	Array,
	Vector,
}

// Spec describes one C-ABI type in a form that renders to C, to Odin and to a
// types.Store. Struct and Union list their member specs; Array and Vector have
// the element spec in members[0] and a count.
Spec :: struct {
	kind:    Spec_Kind,
	scalar:  Scalar,
	members: []int,
	count:   int,
}

VOID :: -1

Signature :: struct {
	params: []int,
	result: int,
}

specs: [dynamic]Spec
signatures: [dynamic]Signature

scalar_bytes :: proc(scalar: Scalar) -> int {
	switch scalar {
	case .U8, .I8, .Bool:
		return 1
	case .U16, .I16, .F16:
		return 2
	case .U32, .I32, .F32:
		return 4
	case .U64, .I64, .F64, .Ptr:
		return 8
	case .U128, .I128:
		return 16
	}
	return 0
}

intern_spec :: proc(wanted: Spec) -> int {
	for existing, index in specs {
		if existing.kind == wanted.kind &&
		   existing.scalar == wanted.scalar &&
		   existing.count == wanted.count &&
		   slice.equal(existing.members, wanted.members) {
			return index
		}
	}
	append(&specs, Spec{wanted.kind, wanted.scalar, slice.clone(wanted.members), wanted.count})
	return len(specs) - 1
}

scalar :: proc(kind: Scalar) -> int {
	return intern_spec(Spec{kind = .Scalar, scalar = kind})
}

record :: proc(kind: Spec_Kind, members: ..int) -> int {
	return intern_spec(Spec{kind = kind, members = members})
}

array :: proc(element: int, count: int) -> int {
	return intern_spec(Spec{kind = .Array, members = {element}, count = count})
}

vector :: proc(element: Scalar, lanes: int) -> int {
	return intern_spec(Spec{kind = .Vector, members = {scalar(element)}, count = lanes})
}

add :: proc(result: int, params: ..int) {
	append(&signatures, Signature{slice.clone(params), result})
}

structure :: proc(kinds: ..Scalar) -> int {
	members := make([]int, len(kinds))
	for kind, index in kinds { members[index] = scalar(kind) }
	return intern_spec(Spec{kind = .Struct, members = members})
}

union_of :: proc(kinds: ..Scalar) -> int {
	members := make([]int, len(kinds))
	for kind, index in kinds { members[index] = scalar(kind) }
	return intern_spec(Spec{kind = .Union, members = members})
}

repeated :: proc(kind: Scalar, count: int) -> []int {
	list := make([]int, count)
	for i in 0 ..< count { list[i] = scalar(kind) }
	return list
}

join :: proc(lists: ..[]int) -> []int {
	joined: [dynamic]int
	for list in lists { append(&joined, ..list) }
	return joined[:]
}

build_cases :: proc() {
	for kind in Scalar {
		add(VOID, scalar(kind))
		add(scalar(kind))
	}

	pair_kinds := []Scalar{.U8, .U32, .U64, .F32, .F64, .Ptr}
	for first in pair_kinds {
		for second in pair_kinds { add(VOID, structure(first, second)) }
	}
	for pair in ([][2]Scalar{{.F16, .F16}, {.F16, .F32}, {.I16, .F16}, {.U8, .U16}, {.Bool, .Bool}, {.F32, .I64}}) {
		add(VOID, structure(pair[0], pair[1]))
	}
	for triple in ([][3]Scalar{{.F32, .F32, .F32}, {.F32, .F32, .U64}, {.U8, .U8, .U8}, {.U32, .U32, .U32}, {.F64, .F32, .F32}, {.U64, .F64, .F64}, {.F16, .F16, .F16}, {.U16, .F16, .F32}, {.U8, .F32, .U8}, {.F64, .U8, .U8}, {.U8, .U16, .U8}, {.F32, .F16, .F16}}) {
		add(VOID, structure(triple[0], triple[1], triple[2]))
		add(structure(triple[0], triple[1], triple[2]))
	}
	for quad in ([][4]Scalar{{.F32, .F32, .F32, .F32}, {.U32, .U32, .U32, .U32}, {.F32, .F32, .F64, .U64}, {.F64, .F64, .F64, .F64}, {.U8, .U8, .U8, .U8}, {.U16, .F16, .F32, .F32}, {.F16, .F16, .F16, .F16}}) {
		add(VOID, structure(quad[0], quad[1], quad[2], quad[3]))
		add(structure(quad[0], quad[1], quad[2], quad[3]))
	}
	for element in ([]Scalar{.U8, .U32, .F32, .F64, .U64, .F16}) {
		for count in ([]int{1, 3, 5, 9}) {
			add(VOID, record(.Struct, array(scalar(element), count)))
		}
	}
	for pair in ([][2]Scalar{{.F32, .U32}, {.F32, .F32}, {.F32, .F64}, {.F64, .U64}, {.U8, .F64}, {.U64, .F64}, {.F16, .U16}}) {
		add(VOID, union_of(pair[0], pair[1]))
		add(union_of(pair[0], pair[1]))
	}
	floats2 := structure(.F32, .F32)
	add(VOID, record(.Union, floats2, scalar(.U64)))
	add(VOID, record(.Union, structure(.U8, .U8, .U8), scalar(.U32)))
	add(VOID, record(.Union, record(.Struct, array(scalar(.F32), 4)), scalar(.F64)))
	add(VOID, record(.Struct, floats2, scalar(.F32)))
	add(VOID, record(.Struct, scalar(.F32), structure(.F32, .U32)))
	add(VOID, record(.Struct, scalar(.U8), structure(.U64, .F32)))
	add(VOID, record(.Struct, structure(.U8, .U8), structure(.F32)))
	add(VOID, record(.Struct, floats2, floats2))
	add(VOID, record(.Struct, array(floats2, 3)))
	add(VOID, record(.Struct, array(structure(.U8, .F32), 2)))
	add(floats2)
	add(record(.Struct, array(floats2, 3)))
	add(record(.Struct, array(scalar(.U64), 3)))
	add(record(.Struct, array(scalar(.F64), 4)))
	add(record(.Struct, array(scalar(.U8), 17)))
	add(record(.Struct, array(scalar(.F32), 17)))

	for used in ([]int{3, 4, 5, 6}) {
		add(VOID, ..join(repeated(.I64, used), {structure(.U64, .U64)}))
		add(VOID, ..join(repeated(.I64, used), {structure(.F64)}))
		add(VOID, ..join(repeated(.I64, used), {structure(.F32, .F32, .F32)}))
	}
	add(VOID, ..join(repeated(.I64, 6), {scalar(.U128)}))
	add(VOID, ..join(repeated(.I64, 5), {scalar(.U128), scalar(.I128)}))
	add(VOID, ..join(repeated(.I64, 5), {record(.Struct, scalar(.U128))}))
	add(VOID, ..join(repeated(.F64, 8), {structure(.F64, .F64)}))
	add(VOID, ..join(repeated(.F64, 8), {structure(.F32)}))
	add(VOID, ..join(repeated(.F64, 7), {structure(.F32, .F32, .F32)}))
	add(VOID, ..join(repeated(.F64, 8), {scalar(.F64), scalar(.I64)}))
	add(VOID, ..join(repeated(.I64, 3), repeated(.F64, 8), {structure(.U64, .F64)}))
	add(VOID, ..join(repeated(.I64, 6), repeated(.F64, 2), {structure(.F64, .F64), structure(.F32)}))
	add(VOID, ..join(repeated(.I64, 5), repeated(.F64, 7), {structure(.F64, .U64), structure(.F64, .U64)}))
	add(VOID, structure(.U64, .U64), structure(.U64, .U64), structure(.U64, .U64), structure(.U64, .U64))
	add(VOID, structure(.F64, .F64), structure(.F64, .F64), structure(.F64, .F64), structure(.F64, .F64), structure(.F64, .F64))
	add(VOID, ..join(repeated(.I64, 6), {vector(.F32, 4), vector(.I32, 4)}))
	add(VOID, scalar(.I8), scalar(.U8), scalar(.I16), scalar(.U16), scalar(.Bool), scalar(.I32), scalar(.U32))

	for shape in ([]struct {
			element: Scalar,
			lanes:   int,
		}{{.F32, 2}, {.F32, 4}, {.I32, 4}, {.F64, 2}, {.F32, 8}, {.U8, 16}, {.F64, 4}}) {
		add(VOID, vector(shape.element, shape.lanes))
		add(vector(shape.element, shape.lanes))
	}
	add(VOID, record(.Struct, vector(.F32, 4)))
	add(record(.Struct, vector(.F32, 4)))
	add(VOID, record(.Struct, vector(.F32, 8)))
	add(VOID, record(.Struct, scalar(.F32), vector(.F32, 4)))
	add(
		VOID,
		..join(
			repeated(.I64, 0),
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
			{vector(.F32, 4)},
		),
	)

	add(VOID, record(.Struct, scalar(.U128)))
	add(VOID, structure(.U64, .U128))
	add(record(.Struct, scalar(.U128)))
	add(VOID, structure(.F16, .F16, .F16, .F16, .F16))
	add(VOID, record(.Struct))
	add(VOID, record(.Struct), scalar(.I64))
}
