package types

// Package types stores immutable semantic type descriptors under deterministic
// Type_Id handles and computes size, alignment, field offsets, and union tags.
// Layout_Config selects target widths and alignment limits; DEFAULT_LAYOUT is
// Linux x86-64. abi_classify.odin assigns System V eightbyte classes and
// abi_plan.odin turns them into the parameter and result pieces of a procedure.
// TYPE_POISON (id 1) is the error-recovery type: any layout request reaching it
// returns Layout_Error.Poison.
