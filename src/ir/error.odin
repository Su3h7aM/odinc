package ir

import "base:runtime"

Error :: union #shared_nil {
	Verify_Code,
	runtime.Allocator_Error,
}

Verify_Code :: enum u8 {
	None,
	Invalid_Anchor, // S1
	Bad_Input_Id, // S2
	Bad_Arity, // S3
	Bad_Type, // S4
	Bad_Projection, // S5
	Bad_Node_Data, // S6
	Removed_Node_Linked, // S7
	Control_Not_Head, // C1
	Head_Exit_Count, // C2
	Unreachable_Head, // C3
	Bad_Loop_Dominance, // C4
	Irreducible, // C5
	Bad_Phi, // C6
	Bad_Memory_Producer, // M1
	Bad_Memory_Operand_Count, // M2
	Bad_Block_Entry_State, // M3
	Bad_Block_Chain, // M4
	Stale_Load, // M5
	Unschedulable_Input, // D1
	Bad_Control_Class, // D2
	Intern_Key_Mismatch, // G1
	Intern_Mutated, // G2
}

Verify_Error :: struct {
	node:  Node_Id,
	other: Node_Id,
	code:  Verify_Code,
}
