// Package ir is a Sea of Nodes intermediate representation for Odin: scalar
// values only, pinned effects, one memory chain per function. The design is
// `docs/02-ir-design.md`.
//
// Vocabulary reused from `core:rexcode/ir`: the `Id` / `ID_NONE` handle idea
// (as `Node_Id` / `NODE_NONE`, with zero reserved instead of all ones) and the
// `Type_Kind` scalar classes (as `Value_Type`). Nothing else from that package
// fits a graph without control and effect edges.
package ir

Node_Id :: distinct u32

NODE_NONE :: Node_Id(0)

Function_Id :: distinct u32

Signature_Id :: distinct u32

Value_Type :: enum u8 {
	None,
	Control,
	Memory,
	Tuple,
	Bool,
	I8,
	I16,
	I32,
	I64,
	F16,
	F32,
	F64,
	Ptr,
	V128,
}

Type_Set :: bit_set[Value_Type;u16]

Node_Flag :: enum u8 {
	Cold,
	Rematerialize,
}

Node_Flags :: bit_set[Node_Flag;u8]
