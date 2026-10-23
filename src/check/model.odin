package check

import "core:math/big"
import "oc:syntax"
import "oc:types"

Entity_Id :: distinct u32
Scope_Id :: distinct u32
Package_Id :: distinct u32
File_Id :: distinct u32
Instance_Id :: distinct u32
Const_Id :: distinct u32
Plan_Id :: distinct u32
Symbol_Id :: distinct u32
View_Id :: distinct u32
Procedure_Info_Origin :: struct {
	signature: Node_Ref,
	scope:     Scope_Id,
	view:      View_Id,
}

Procedure_Info :: struct {
	defaults:                                      []Default_Argument,
	parameter_flags:                               []Entity_Flags,
	// Raw comma-separated `@(require_target_feature)` / `@(enable_target_feature)` lists of the
	// declaration that produced this signature; empty when the procedure declares neither.
	require_target_feature, enable_target_feature: string,
}

Procedure_Info_Entry :: struct {
	id:     types.Procedure_Info_Id,
	origin: Procedure_Info_Origin,
	info:   ^Procedure_Info,
}

Procedure_Info_Error :: enum u8 {
	None,
	Invalid_Id,
}
Builtin_Id :: distinct u32

Builtin_Kind :: enum u16 {
	None,
	Syscall,
	Len,
	Cap,
	Raw_Data,
	Size_Of,
	Align_Of,
	Offset_Of,
	Offset_Of_By_String,
	Trap,
	Unreachable,
	Min,
	Max,
	Abs,
	Clamp,
	Count_Ones,
	Count_Zeros,
	Count_Leading_Zeros,
	Count_Trailing_Zeros,
	Reverse_Bits,
	Byte_Swap,
	Expect,
	Volatile_Load,
	Volatile_Store,
	Atomic_Load,
	Atomic_Store,
	Atomic_Add,
	Atomic_Sub,
	Atomic_And,
	Atomic_Nand,
	Atomic_Or,
	Atomic_Xor,
	Atomic_Exchange,
	Atomic_Compare_Exchange_Strong,
	Atomic_Compare_Exchange_Weak,
	Atomic_Load_Explicit,
	Atomic_Store_Explicit,
	Atomic_Add_Explicit,
	Atomic_Sub_Explicit,
	Atomic_And_Explicit,
	Atomic_Nand_Explicit,
	Atomic_Or_Explicit,
	Atomic_Xor_Explicit,
	Atomic_Exchange_Explicit,
	Atomic_Compare_Exchange_Strong_Explicit,
	Atomic_Compare_Exchange_Weak_Explicit,
	Atomic_Thread_Fence,
	Atomic_Signal_Fence,
	Overflow_Add,
	Overflow_Sub,
	Overflow_Mul,
	Mem_Copy,
	Mem_Copy_Non_Overlapping,
	Mem_Zero,
	Mem_Zero_Volatile,
	Cpu_Relax,
	Debug_Trap,
	Typeid_Of,
	Has_Target_Feature,
	Unaligned_Load,
	Unaligned_Store,
	Simd_Extract,
	Simd_Replace,
	Simd_Indices,
	Simd_Select,
	Simd_Shuffle,
	Simd_Lanes_Ne,
	Simd_Lanes_Eq,
	Simd_Lanes_Lt,
	Simd_Lanes_Le,
	Simd_Lanes_Gt,
	Simd_Lanes_Ge,
	Simd_Add,
	Simd_Sub,
	Simd_Mul,
	Simd_Div,
	Simd_Bit_And,
	Simd_Bit_Or,
	Simd_Bit_Xor,
	Simd_Bit_And_Not,
	Simd_Min,
	Simd_Max,
	Simd_Shl,
	Simd_Shr,
	Simd_Shl_Masked,
	Simd_Shr_Masked,
	Simd_Reduce_Or,
	Simd_Reduce_Min,
	Constant_Log2,
	Saturating_Add,
	Saturating_Sub,
	Type_Array,
	Type_Pointer,
	Type_Struct,
	Type_Slice,
	Type_Integer,
	Type_Float,
	Type_Numeric,
	Type_Unsigned,
	Type_Proc,
	Type_Internally_Pointer_Like,
	Type_Boolean,
	Type_Multi_Pointer,
	Type_Dynamic_Array,
	Type_Map,
	Type_Union,
	Type_Enum,
	Type_Bit_Set,
	Type_Struct_Field_Count,
	Type_Has_Field,
	Type_Field_Type,
	Type_Bit_Set_Underlying_Type,
	Type_Elem_Type,
	Type_Info_Of,
	Type_Map_Info,
	Type_Map_Cell_Info,
	Type_Comparable,
	Type_Ordered,
	Type_Ordered_Numeric,
	Type_Simple_Compare,
	Type_Enumerated_Array,
	Type_Base_Type,
	Type_Core_Type,
	Sqrt,
	Ptr_Offset,
	Ptr_Sub,
	Entry_Point,
	Read_Cycle_Counter,
	X86_Cpuid,
	X86_Xgetbv,
	X86_Aesenc,
	X86_Aesenclast,
	X86_Aesimc,
	X86_Aeskeygenassist,
	X86_Aesdec,
	X86_Aesdeclast,
	X86_Pclmulqdq,
	X86_Sha256msg1,
	X86_Sha256msg2,
	X86_Sha256rnds2,
	Complex,
	Quaternion,
	Real,
	Imag,
	Jmag,
	Kmag,
	Conj,
	Address_Of_Return_Address,
	Alloca,
	Atomic_Type_Is_Lock_Free,
	Concatenate,
	Constant_Ceil,
	Constant_Floor,
	Constant_Round,
	Constant_Trunc,
	Constant_Utf16_Cstring,
	Count_Leading_Ones,
	Count_Trailing_Ones,
	C_Va_Arg,
	C_Va_Copy,
	C_Va_End,
	C_Va_Start,
	Fixed_Point_Div,
	Fixed_Point_Div_Sat,
	Fixed_Point_Mul,
	Fixed_Point_Mul_Sat,
	Frame_Address,
	Fused_Mul_Add,
	Hadamard_Product,
	Is_Package_Imported,
	Likely,
	Matrix_Flatten,
	Non_Temporal_Load,
	Non_Temporal_Store,
	Objc_Block,
	Objc_Find_Class,
	Objc_Find_Selector,
	Objc_Ivar_Get,
	Objc_Register_Class,
	Objc_Register_Selector,
	Objc_Super,
	Outer_Product,
	Prefetch_Read_Data,
	Prefetch_Read_Instruction,
	Prefetch_Write_Data,
	Prefetch_Write_Instruction,
	Procedure_Of,
	Read_Cycle_Counter_Frequency,
	Return_Address,
	Simd_Abs,
	Simd_Approx_Recip,
	Simd_Approx_Recip_Sqrt,
	Simd_Ceil,
	Simd_Clamp,
	Simd_Deinterleave,
	Simd_Extract_Lsbs,
	Simd_Extract_Msbs,
	Simd_Floor,
	Simd_Gather,
	Simd_Interleave,
	Simd_Lanes_Reverse,
	Simd_Lanes_Rotate_Left,
	Simd_Lanes_Rotate_Right,
	Simd_Masked_Compress_Store,
	Simd_Masked_Expand_Load,
	Simd_Masked_Load,
	Simd_Masked_Store,
	Simd_Nearest,
	Simd_Neg,
	Simd_Odd_Even,
	Simd_Pairwise_Add,
	Simd_Pairwise_Sub,
	Simd_Reduce_Add_Bisect,
	Simd_Reduce_Add_Ordered,
	Simd_Reduce_Add_Pairs,
	Simd_Reduce_All,
	Simd_Reduce_And,
	Simd_Reduce_Any,
	Simd_Reduce_Max,
	Simd_Reduce_Mul_Bisect,
	Simd_Reduce_Mul_Ordered,
	Simd_Reduce_Mul_Pairs,
	Simd_Reduce_Xor,
	Simd_Runtime_Swizzle,
	Simd_Saturating_Add,
	Simd_Saturating_Sub,
	Simd_Scatter,
	Simd_Sums_Of_N,
	Simd_To_Bits,
	Simd_To_Bits_Signed,
	Simd_Trunc,
	Soa_Copy_From_Slice,
	Soa_Struct,
	Soa_Zip,
	Soa_Unzip,
	Stack_Pointer,
	Syscall_Bsd,
	Transpose,
	Type_Bit_Set_Elem_Type,
	Type_Canonical_Name,
	Type_Convert_Variants_To_Pointers,
	Type_Enum_Is_Contiguous,
	Type_Equal_Proc,
	Type_Field_Bit_Offset,
	Type_Field_Bit_Size,
	Type_Field_Index_Of,
	Type_Fixed_Capacity_Dynamic_Array_Len_Offset,
	Type_Hasher_Proc,
	Type_Has_Nil,
	Type_Has_Shared_Fields,
	Type_Integer_To_Signed,
	Type_Integer_To_Unsigned,
	Type_Is_Any,
	Type_Is_Bit_Field,
	Type_Is_Complex,
	Type_Is_Cstring,
	Type_Is_Cstring16,
	Type_Is_Dereferenceable,
	Type_Is_Endian_Big,
	Type_Is_Endian_Little,
	Type_Is_Endian_Platform,
	Type_Is_Fixed_Capacity_Dynamic_Array,
	Type_Is_Indexable,
	Type_Is_Matrix,
	Type_Is_Matrix_Column_Major,
	Type_Is_Matrix_Row_Major,
	Type_Is_Named,
	Type_Is_Nearly_Simple_Compare,
	Type_Is_Quaternion,
	Type_Is_Rune,
	Type_Is_Simd_Vector,
	Type_Is_Sliceable,
	Type_Is_Specialization_Of,
	Type_Is_Specialized_Polymorphic_Record,
	Type_Is_String,
	Type_Is_String16,
	Type_Is_Subtype_Of,
	Type_Is_Superset_Of,
	Type_Is_Typeid,
	Type_Is_Unspecialized_Polymorphic_Record,
	Type_Is_Valid_Map_Key,
	Type_Is_Valid_Matrix_Elements,
	Type_Is_Variant_Of,
	Type_Merge,
	Type_Polymorphic_Record_Parameter_Count,
	Type_Polymorphic_Record_Parameter_Value,
	Type_Proc_Calling_Convention,
	Type_Proc_Parameter_Count,
	Type_Proc_Parameter_Type,
	Type_Proc_Return_Count,
	Type_Proc_Return_Type,
	Type_Struct_Has_Implicit_Padding,
	Type_Union_Base_Tag_Value,
	Type_Union_Tag_Offset,
	Type_Union_Tag_Type,
	Type_Union_Variant_Count,
	Type_Variant_Index_Of,
	Type_Variant_Type_Of,
	Unlikely,
	Valgrind_Client_Request,
	Wasm_Memory_Atomic_Notify32,
	Wasm_Memory_Atomic_Wait32,
	Wasm_Memory_Grow,
	Wasm_Memory_Size,
	Swizzle,
}


Source_Span :: struct {
	file:       File_Id,
	start, end: u32,
}
Node_Ref :: struct {
	file: File_Id,
	node: syntax.Node_Index,
}
Expression_Ref :: struct {
	view: View_Id,
	node: syntax.Node_Index,
}
Source_Order :: struct {
	package_order, file_order, offset, declaration_index: u32,
}

Resolution_State :: enum u8 {
	Unresolved,
	Resolving,
	Resolved,
	Invalid,
}
Body_State :: enum u8 {
	Unchecked,
	Checking,
	Complete,
	Invalid,
}
Node_State :: enum u8 {
	Unseen,
	Inactive,
	Checked,
	Invalid,
}
Package_Kind :: enum u8 {
	Invalid,
	User,
	Runtime,
	Builtin,
	Intrinsics,
	Config,
}
Package_Phase :: enum u8 {
	None,
	Collected,
	Imports,
	Globals,
	Bodies,
	Complete,
	Invalid,
}
Scope_Kind :: enum u8 {
	Invalid,
	Universal,
	Package,
	File,
	Procedure,
	Block,
	Type_Member,
}
Check_Policy :: enum u8 {
	Unspecified,
	Enabled,
	Disabled,
}
Division_By_Zero :: enum u8 {
	Unspecified,
	Trap,
	Zero,
	Self,
	All_Bits,
}

Addressing_Mode :: enum u8 {
	Invalid,
	No_Value,
	Value,
	Immutable_Value,
	Variable,
	Constant,
	Type,
	Builtin,
	Procedure_Group,
	Map_Index,
	Optional_Ok,
	Optional_Ok_Pointer,
	Context,
	Soa_Variable,
	Soa_Pointer,
	Swizzle_Value,
	Swizzle_Variable,
}

Entity_Kind :: enum u8 {
	Invalid,
	Constant,
	Variable,
	Type_Name,
	Procedure,
	Procedure_Group,
	Builtin,
	Import_Name,
	Library_Name,
	Nil,
	Label,
	Assembly_Template,
}
Entity_Flag :: enum u8 {
	Using,
	Subtype,
	Parameter,
	Result,
	Field,
	Immutable,
	Type_Alias,
	Private_Package,
	Private_File,
	Export,
	Foreign,
	Lazy,
	Required,
	Disabled,
	No_Alias,
	No_Capture,
	By_Pointer,
	Variadic,
	C_Variadic,
	Any_Integer,
	No_Broadcast,
	Test,
	Used,
	In_When,
	Rodata,
	// A file-scope `::` binding of a composite literal, kept as an immutable global; the official checker classifies it Addressing_Constant.
	Demoted_Constant,
}
Entity_Flags :: bit_set[Entity_Flag;u64]

File_Policy :: struct {
	bounds_check, type_assert: Check_Policy,
	division_by_zero:          Division_By_Zero,
	features:                  []string,
}
Import_Edge :: struct {
	declaration: Node_Ref,
	package_id:  Package_Id,
}
Package :: struct {
	key, name:  string,
	kind:       Package_Kind,
	phase:      Package_Phase,
	scope:      Scope_Id,
	files:      []File_Id,
	imports:    []Import_Edge,
	init_order: u32,
}
File :: struct {
	package_id:         Package_Id,
	path, display_path: string,
	source:             []byte,
	lines:              syntax.Line_Table,
	ast:                ^syntax.Ast,
	scope:              Scope_Id,
	policy:             File_Policy,
	imports:            []Node_Ref,
}
Member_Step :: struct {
	type:        types.Type_Id,
	field_index: u32,
	indirect:    bool,
}
Using_Binding :: struct {
	name:           string,
	entity, origin: Entity_Id,
	root:           Operand,
	path:           []Member_Step,
}
Scope :: struct {
	parent:         Scope_Id,
	kind:           Scope_Kind,
	owner:          Entity_Id,
	order:          Source_Order,
	declarations:   []Entity_Id,
	lookup:         map[string]Entity_Id,
	using_bindings: []Using_Binding,
}
Dependency_Kind :: enum u8 {
	Name,
	Signature,
	Constant,
	Layout,
	Body,
	Initialization,
	Runtime,
	Type_Info,
}
Dependency :: struct {
	entity: Entity_Id,
	kind:   Dependency_Kind,
	source: Source_Span,
}
Attribute :: struct {
	name:   string,
	value:  Const_Id,
	// Resolved target of a deferred_* attribute. The constant pool cannot
	// name a procedure entity, and the target may be declared later.
	entity: Entity_Id,
	source: Source_Span,
}
// Which deferred_* attribute names a procedure, if any. Stored on the
// attribute name itself; the target lives in Attribute.entity.
Deferred_Kind :: enum u8 {
	Absent,
	Legacy,
	None,
	In,
	Out,
	In_Out,
	By_Ptr,
}
Storage_Kind :: enum u8 {
	None,
	Local,
	Global,
	Thread_Local,
}
Variable_Data :: struct {
	storage:          Storage_Kind,
	initializer:      Node_Ref,
	initializer_view: View_Id,
	value:            Node_Ref,
}
Procedure_Group_Data :: struct {
	members: []Entity_Id,
}
Import_Data :: struct {
	package_id: Package_Id,
}
Library_Path :: struct {
	system: bool,
	name:   string,
}
Library_Data :: struct {
	paths:       []Library_Path,
	// Path expressions that are not string literals, until check_library_paths evaluates them into `paths`.
	expressions: []syntax.Node_Index,
	used:        bool,
}
Label_Data :: struct {
	target: Node_Ref,
	scope:  Scope_Id,
}
// Absent: no default. Invalid: a default rejected where it was declared, which already reports the error.
// Declaration stores syntax in its declaring scope; Value holds a checked operand.
Default_Kind :: enum u8 {
	Absent,
	Invalid,
	Constant,
	Value,
	Declaration,
	Caller_Location,
	Caller_Expression,
}
// For Caller_Expression, an empty source_parameter captures the call's own expression text.
Default_Argument :: struct {
	kind:              Default_Kind,
	value:             Operand,
	conversion:        Plan_Id,
	source_parameter:  string,
	declaration_scope: Scope_Id,
	target_type:       types.Type_Id,
}
Procedure_Data :: struct {
	source_name:         string,
	parameters, results: []Entity_Id,
	defaults:            []Default_Argument,
	result_defaults:     []Default_Argument,
	signature:           types.Type_Id,
	convention:          types.Calling_Convention,
	variadic_index:      int,
	body:                Node_Ref,
	where_clauses:       syntax.Node_Range,
	body_state:          Body_State,
	definition:          Entity_Id,
	instance:            Instance_Id,
	defers:              []Defer_Registration,
	generic:             bool,
	assigns_context:     bool,
	poly_arguments:      []types.Type_Id,
	poly_constants:      []Const_Id,
	atomic:              Atomic_Attributes,
}
Entity_Data :: union {
	Variable_Data,
	Procedure_Data,
	Procedure_Group_Data,
	Import_Data,
	Library_Data,
	Label_Data,
	Builtin_Id,
}
Entity :: struct {
	name:            string,
	kind:            Entity_Kind,
	flags:           Entity_Flags,
	scope:           Scope_Id,
	package_id:      Package_Id,
	declaration:     Node_Ref,
	order:           Source_Order,
	state:           Resolution_State,
	type:            types.Type_Id,
	constant:        Const_Id,
	attributes:      []Attribute,
	dependencies:    []Dependency,
	alias:           Entity_Id,
	data:            Entity_Data,
	foreign_library: string,
	link_name:       string,
}

Typed_Nodes :: struct {
	types:     []types.Type_Id,
	constants: []Const_Id,
	modes:     []Addressing_Mode,
	entities:  []Entity_Id,
	plans:     []Plan_Id,
	scopes:    []Scope_Id,
	states:    []Node_State,
}
Typed_View :: struct {
	file:       File_Id,
	instance:   Instance_Id,
	parent:     View_Id,
	origin:     Source_Span,
	first_node: syntax.Node_Index,
	nodes:      Typed_Nodes,
	// References checked outside an instance's declaration.
	extra_rows: map[syntax.Node_Index]Expression_Info,
}
Expression_Info :: struct {
	type:     types.Type_Id,
	constant: Const_Id,
	mode:     Addressing_Mode,
	entity:   Entity_Id,
	plan:     Plan_Id,
	scope:    Scope_Id,
	state:    Node_State,
}

Float_Value :: struct {
	bits:  u64,
	width: u8,
}
Complex_Value :: [2]Const_Id
Quaternion_Value :: [4]Const_Id
Pointer_Value :: distinct u64
Address_Value :: struct {
	symbol: Symbol_Id,
	addend: i64,
}
Aggregate_Value :: struct {
	elements: []Const_Id,
}
Variant_Value :: struct {
	type:  types.Type_Id,
	value: Const_Id,
}
Nil_Value :: struct {}
Uninitialized_Value :: struct {}
Constant_Value :: union {
	bool,
	big.Int,
	big.Rat,
	Float_Value,
	Complex_Value,
	Quaternion_Value,
	string,
	[]u16,
	Pointer_Value,
	Address_Value,
	Entity_Id,
	types.Type_Id,
	Aggregate_Value,
	Variant_Value,
	Nil_Value,
	Uninitialized_Value,
	Node_Ref,
}
Constant :: struct {
	type:  types.Type_Id,
	value: Constant_Value,
}
Projection :: struct {
	expression: Expression_Ref,
	index:      u32,
}
Operand :: union {
	Expression_Ref,
	Const_Id,
	Entity_Id,
	Projection,
}
Conversion_Kind :: enum u8 {
	Invalid,
	Assignment,
	Cast,
	Transmute,
	Subtype,
	Box,
	Union_Injection,
	Broadcast,
	Type_Assertion,
}
Conversion_Plan :: struct {
	kind:               Conversion_Kind,
	source:             Operand,
	target:             types.Type_Id,
	source_type:        types.Type_Id,
	path:               []Member_Step,
	// A `.Box` of an addressable operand refers to the variable itself, as official Odin does.
	source_addressable: bool,
}
Place_Plan :: struct {
	root:                 Operand,
	path:                 []Member_Step,
	bit_offset, bit_size: u32,
}
Swizzle_Plan :: struct {
	root:     Operand,
	indices:  []i64,
	count:    int,
	indirect: bool,
}
Binary_Conversion_Plan :: struct {
	left, right: Plan_Id,
	type:        types.Type_Id,
}
Ternary_Conversion_Plan :: struct {
	x, y: Plan_Id,
}
Range_Call_Plan :: struct {
	call:            Expression_Ref,
	value_types:     []types.Type_Id,
	value_count:     u32,
	condition_index: u32,
}
Call_Argument :: struct {
	value:                   Operand,
	parameter:               Entity_Id,
	conversion:              Plan_Id,
	evaluation_order:        u32,
	caller_location:         bool,
	variadic_pack:           bool,
	variadic_elements:       []Operand,
	variadic_spread:         bool,
	variadic_conversions:    []Plan_Id,
	tuple_element:           int,
	variadic_tuple_elements: []int,
	receiver:                Receiver_Form,
	promoted_type:           types.Type_Id,
}
// The object that owns a `->` call's field, passed as the first argument: by value, or by its address.
Receiver_Form :: enum u8 {
	None,
	Value,
	Address,
	Box,
}
Call_Plan :: struct {
	callee:       Operand,
	entity:       Entity_Id,
	instance:     Instance_Id,
	arguments:    []Call_Argument,
	results:      []types.Type_Id,
	context_plan: Plan_Id,
	variadic:     bool,
	// Deferred procedure of the callee; 0 when the callee declares none.
	// Backfilled after checking so lowering finds the call-site defer.
	deferred:     Entity_Id,
}
Builtin_Plan :: struct {
	builtin:   Builtin_Id,
	arguments: []Operand,
	helpers:   []Entity_Id,
	results:   []types.Type_Id,
	// The type operand of type_hasher_proc; zero for every other builtin.
	type:      types.Type_Id,
}
Aggregate_Plan :: struct {
	type:          types.Type_Id,
	values:        []Operand,
	field_indices: []u32,
	field_paths:   [][]Member_Step,
	conversions:   []Plan_Id,
}
Slice_Literal_Plan :: struct {
	type:    types.Type_Id,
	backing: Aggregate_Plan,
}
Dynamic_Array_Literal_Plan :: struct {
	type:    types.Type_Id,
	backing: Aggregate_Plan,
}
Map_Literal_Plan :: struct {
	type:                               types.Type_Id,
	keys, values:                       []Operand,
	key_conversions, value_conversions: []Plan_Id,
}
Assignment_Plan :: struct {
	destinations, values: []Operand,
	conversions:          []Plan_Id,
	initializes:          []bool,
}
Bounds_Kind :: enum u8 {
	Index,
	Slice,
	Multi_Pointer,
	Matrix,
	Soa,
}
Bounds_Plan :: struct {
	kind:     Bounds_Kind,
	operands: []Operand,
	policy:   Check_Policy,
	helper:   Entity_Id,
}

// One lvalue or rvalue of an #soa container: the soa struct value, the element
// index and the selected field. A nil field is the whole element; a constant
// field is one spread field (a struct field or an array component); an
// expression field is a runtime array component, as in `s[i][j]`.
Soa_Plan :: struct {
	container: Operand,
	index:     Operand,
	field:     Operand,
	soa:       types.Type_Id,
	policy:    Check_Policy,
}
Union_Operation :: enum u8 {
	Inject,
	Assert,
	Optional_Assert,
	Type_Switch,
}
Union_Plan :: struct {
	operation: Union_Operation,
	value:     Operand,
	variant:   types.Type_Id,
	helper:    Entity_Id,
}
Exit_Kind :: enum u8 {
	None,
	Return,
	Break,
	Continue,
	Fallthrough,
}
Exit_Plan :: struct {
	kind:          Exit_Kind,
	target:        Node_Ref,
	exited_scopes: []Scope_Id,
	values:        []Operand,
	conversions:   []Plan_Id,
}
Optional_Test :: enum u8 {
	Boolean_True,
	Nil,
}
Propagation_Plan :: struct {
	operand:             Operand,
	test:                Optional_Test,
	values:              []Operand,
	failure:             Plan_Id,
	fallback_conversion: Plan_Id,
	// Payload types of an or_return with more than one value. Empty for or_else and a single payload.
	results:             []types.Type_Id,
}
Context_Plan :: struct {
	parent: Plan_Id,
	scope:  Scope_Id,
	value:  Operand,
	copy:   bool,
}
Plan :: union {
	Binary_Conversion_Plan,
	Ternary_Conversion_Plan,
	Conversion_Plan,
	Place_Plan,
	Swizzle_Plan,
	Range_Call_Plan,
	Call_Plan,
	Builtin_Plan,
	Aggregate_Plan,
	Slice_Literal_Plan,
	Dynamic_Array_Literal_Plan,
	Map_Literal_Plan,
	Bit_Set_Literal_Plan,
	Assignment_Plan,
	Bounds_Plan,
	Matrix_Index_Plan,
	Matrix_Vector_Plan,
	Matrix_Binary_Plan,
	Union_Plan,
	Exit_Plan,
	Propagation_Plan,
	Context_Plan,
	Typeid_Plan,
	Type_Info_Plan,
	Map_Info_Plan,
	Map_Cell_Info_Plan,
	Comparison_Plan,
	Switch_Plan,
	Type_Switch_Plan,
	Interval_Plan,
	Type_Assertion_Plan,
	Map_Index_Plan,
	Address_Plan,
	Soa_Plan,
}
Switch_Plan :: struct {
	tag:         Entity_Id,
	comparisons: []Plan_Id,
}
Type_Switch_Clause :: struct {
	entity:   Entity_Id,
	variants: []types.Type_Id,
}
// Clause variants are the case types; types.TYPE_UNTYPED_NIL marks `nil`, and no variants marks the default clause.
Type_Switch_Plan :: struct {
	subject:      Operand,
	subject_type: types.Type_Id,
	reference:    bool,
	clauses:      []Type_Switch_Clause,
}
Type_Assertion_Plan :: struct {
	policy:      Check_Policy,
	source:      Operand,
	source_type: types.Type_Id,
	target_type: types.Type_Id,
	variant:     int,
	comma_ok:    bool,
}
Defer_Registration :: struct {
	scope:        Scope_Id,
	statement:    Node_Ref,
	context_plan: Plan_Id,
}

Symbol_Kind :: enum u8 {
	None,
	Procedure,
	Global,
	Extern,
}
Linkage :: enum u8 {
	Internal,
	Strong,
	Weak,
	Link_Once,
}
Visibility :: enum u8 {
	Default,
	Hidden,
	Protected,
}
Symbol :: struct {
	entity:       Entity_Id,
	kind:         Symbol_Kind,
	name:         string,
	type:         types.Type_Id,
	linkage:      Linkage,
	visibility:   Visibility,
	thread_local: bool,
	section:      string,
	alignment:    u32,
	library:      Entity_Id,
}
Generated_Body_Kind :: enum u8 {
	None,
	Equality,
	Hasher,
	Map,
}
Generated_Body :: struct {
	kind: Generated_Body_Kind,
	type: types.Type_Id,
}
Checked_Procedure :: struct {
	entity:              Entity_Id,
	symbol:              Symbol_Id,
	signature:           types.Type_Id,
	body:                Node_Ref,
	generated:           Generated_Body,
	view:                View_Id,
	parameters, results: []Entity_Id,
	result_defaults:     []Default_Argument,
	convention:          types.Calling_Convention,
	// Parsed `@(enable_target_feature)` list, plus the global level the procedure was checked against.
	target_features:     types.X86_Features,
	microarch:           types.X86_Level,
	attributes:          []Attribute,
	source:              Source_Span,
	defers:              []Defer_Registration,
}
Relocation :: struct {
	offset: u64,
	target: Symbol_Id,
	addend: i64,
}
Global :: struct {
	entity:           Entity_Id,
	symbol:           Symbol_Id,
	type:             types.Type_Id,
	alignment:        u32,
	thread_local:     bool,
	initializer:      Const_Id,
	relocations:      []Relocation,
	initializer_node: Node_Ref,
	initializer_view: View_Id,
}
Ordered_Procedure :: struct {
	entity:   Entity_Id,
	priority: i64,
}
Type_Info_Entry :: struct {
	type:            types.Type_Id,
	runtime_id:      u64,
	slot:            u32,
	name, pkg:       string,
	base_slot:       u32,
	size, alignment: i64,
	flags:           u32,
	descriptor:      Const_Id,
	symbol:          Symbol_Id,
}
Runtime_Requirements :: struct {
	schema_entities, helper_entities: []Entity_Id,
	dependencies:                     []Dependency,
	type_info:                        []Type_Info_Entry,
	type_info_representatives:        []types.Type_Id,
	type_info_type:                   types.Type_Id,
	type_info_parameters_type:        types.Type_Id,
	enum_members:                     []Enum_Type_Members,
	map_cell_info:                    []Map_Cell_Info_Entry,
	map_info:                         []Map_Info_Entry,
	type_table:                       Symbol_Id,
	entry_point:                      Entity_Id,
	tests:                            []Entity_Id,
	init_procedures, fini_procedures: []Ordered_Procedure,
	init_context:                     Entity_Id,
}

// Every slice, map, source and type store is borrowed and remains valid through lowering.
// Handle-indexed tables reserve entry zero; ordered procedure/global lists do not.
Checked_Program :: struct {
	packages:              []Package,
	files:                 []File,
	entities:              []Entity,
	scopes:                []Scope,
	typed_views:           []Typed_View,
	plan_table:            []Plan,
	constant_table:        []Constant,
	symbol_table:          []Symbol,
	entity_symbols:        []Symbol_Id,
	builtin_kinds:         []Builtin_Kind,
	procedure_list:        []Checked_Procedure,
	global_list:           []Global,
	global_initialization: []Entity_Id,
	type_data:             ^types.Store,
	runtime:               Runtime_Requirements,
	// Global baseline level the universe was bound with; lowered functions add their own enable sets to it.
	microarch:             types.X86_Level,
}

// The returned row is a copy; its referenced plans and constants remain borrowed.
expression_info :: proc(program: ^Checked_Program, view: View_Id, node: syntax.Node_Index) -> (info: Expression_Info, ok: bool) #optional_ok {
	if program == nil || node == 0 { return }
	typed := table_entry(program.typed_views, view)
	if typed == nil { return }
	return typed_view_info(typed, node)
}

@(private)
typed_view_info :: proc(typed: ^Typed_View, node: syntax.Node_Index) -> (info: Expression_Info, ok: bool) #optional_ok {
	if node == 0 { return }
	if node < typed.first_node || int(node - typed.first_node) >= len(typed.nodes.types) {
		return typed.extra_rows[node]
	}
	index := int(node - typed.first_node)
	nodes := typed.nodes
	count := len(nodes.types)
	assert(len(nodes.constants) == count && len(nodes.modes) == count && len(nodes.entities) == count)
	assert(len(nodes.plans) == count && len(nodes.scopes) == count && len(nodes.states) == count)
	return Expression_Info {
			nodes.types[index],
			nodes.constants[index],
			nodes.modes[index],
			nodes.entities[index],
			nodes.plans[index],
			nodes.scopes[index],
			nodes.states[index],
		},
		true
}

@(private)
typed_view_store :: proc(typed: ^Typed_View, node: syntax.Node_Index, info: Expression_Info) {
	if node < typed.first_node || int(node - typed.first_node) >= len(typed.nodes.types) {
		typed.extra_rows[node] = info
		return
	}
	index := int(node - typed.first_node)
	rows := typed.nodes
	rows.types[index], rows.constants[index], rows.modes[index], rows.entities[index] = info.type, info.constant, info.mode, info.entity
	rows.plans[index], rows.scopes[index], rows.states[index] = info.plan, info.scope, info.state
}

procedures :: proc(program: ^Checked_Program) -> []Checked_Procedure {
	if program == nil { return nil }
	return program.procedure_list
}
plan :: proc(program: ^Checked_Program, id: Plan_Id) -> ^Plan {
	if program == nil { return nil }
	return table_entry(program.plan_table, id)
}
symbols :: proc(program: ^Checked_Program) -> []Symbol {
	if program == nil || len(program.symbol_table) == 0 { return nil }
	return program.symbol_table[1:]
}
entity_symbol :: proc(program: ^Checked_Program, entity: Entity_Id) -> Symbol_Id {
	if program == nil { return 0 }
	symbol := table_entry(program.entity_symbols, entity)
	if symbol == nil { return 0 }
	return symbol^
}
builtin_kind :: proc(program: ^Checked_Program, id: Builtin_Id) -> Builtin_Kind {
	if program == nil { return .None }
	kind := table_entry(program.builtin_kinds, id)
	if kind == nil { return .None }
	return kind^
}
globals :: proc(program: ^Checked_Program) -> []Global {
	if program == nil { return nil }
	return program.global_list
}
constants :: proc(program: ^Checked_Program) -> []Constant {
	if program == nil || len(program.constant_table) == 0 { return nil }
	return program.constant_table[1:]
}
constant :: proc(program: ^Checked_Program, id: Const_Id) -> ^Constant {
	if program == nil { return nil }
	return table_entry(program.constant_table, id)
}
type_store :: proc(program: ^Checked_Program) -> ^types.Store {
	if program == nil { return nil }
	return program.type_data
}
runtime_requirements :: proc(program: ^Checked_Program) -> ^Runtime_Requirements {
	if program == nil { return nil }
	return &program.runtime
}
sources :: proc(program: ^Checked_Program) -> []File {
	if program == nil || len(program.files) == 0 { return nil }
	return program.files[1:]
}

@(private = "file")
table_entry :: proc(table: []$T, id: $Id) -> ^T {
	index := int(id)
	if index <= 0 || index >= len(table) { return nil }
	return &table[index]
}
