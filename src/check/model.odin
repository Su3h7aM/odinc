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
Builtin_Id :: distinct u32

Builtin_Kind :: enum u8 {
	None,
	Syscall,
	Len,
	Cap,
	Raw_Data,
	Size_Of,
	Align_Of,
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
	Typeid_Of,
	Has_Target_Feature,
	Unaligned_Load,
	Simd_Indices,
	Simd_Select,
	Simd_Lanes_Ne,
	Simd_Reduce_Or,
	Simd_Reduce_Min,
	Constant_Log2,
	Type_Info_Of,
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
}
Entity_Flags :: bit_set[Entity_Flag;u64]

File_Policy :: struct {
	bounds_check, type_assert: Check_Policy,
	division_by_zero:          Division_By_Zero,
	features, vet:             []string,
}
Import_Edge :: struct {
	declaration: Node_Ref,
	package_id:  Package_Id,
}
Package :: struct {
	key, name: string,
	kind:      Package_Kind,
	phase:     Package_Phase,
	scope:     Scope_Id,
	files:     []File_Id,
	imports:   []Import_Edge,
}
File :: struct {
	package_id:         Package_Id,
	path, display_path: string,
	source:             []byte,
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
	name:                 string,
	entity, origin, root: Entity_Id,
	path:                 []Member_Step,
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
	source: Source_Span,
}
Storage_Kind :: enum u8 {
	None,
	Local,
	Global,
	Thread_Local,
}
Variable_Data :: struct {
	storage:     Storage_Kind,
	initializer: Node_Ref,
}
Procedure_Group_Data :: struct {
	members: []Entity_Id,
}
Import_Data :: struct {
	package_id: Package_Id,
}
Library_Data :: struct {
	collection: string,
	paths:      []string,
}
Label_Data :: struct {
	target: Node_Ref,
	scope:  Scope_Id,
}
Default_Argument :: struct {
	value:                    Operand,
	caller_location:          bool,
	caller_expression:        bool,
	caller_expression_target: string,
}
Procedure_Data :: struct {
	parameters, results: []Entity_Id,
	defaults:            []Default_Argument,
	signature:           types.Type_Id,
	convention:          types.Calling_Convention,
	body:                Node_Ref,
	body_state:          Body_State,
	definition:          Entity_Id,
	instance:            Instance_Id,
	defers:              []Defer_Registration,
	generic:             bool,
	poly_arguments:      []types.Type_Id,
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
	name:         string,
	kind:         Entity_Kind,
	flags:        Entity_Flags,
	scope:        Scope_Id,
	package_id:   Package_Id,
	declaration:  Node_Ref,
	order:        Source_Order,
	state:        Resolution_State,
	type:         types.Type_Id,
	constant:     Const_Id,
	attributes:   []Attribute,
	dependencies: []Dependency,
	data:         Entity_Data,
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
}
Conversion_Plan :: struct {
	kind:   Conversion_Kind,
	source: Operand,
	target: types.Type_Id,
	path:   []Member_Step,
}
Place_Plan :: struct {
	root:                 Operand,
	path:                 []Member_Step,
	bit_offset, bit_size: u32,
}
Call_Argument :: struct {
	value:             Operand,
	parameter:         Entity_Id,
	conversion:        Plan_Id,
	evaluation_order:  u32,
	caller_location:   bool,
	variadic_pack:     bool,
	variadic_elements: []Operand,
}
Call_Plan :: struct {
	callee:       Operand,
	entity:       Entity_Id,
	instance:     Instance_Id,
	arguments:    []Call_Argument,
	results:      []types.Type_Id,
	context_plan: Plan_Id,
	variadic:     bool,
}
Builtin_Plan :: struct {
	builtin:   Builtin_Id,
	arguments: []Operand,
	helpers:   []Entity_Id,
	results:   []types.Type_Id,
}
Aggregate_Plan :: struct {
	type:          types.Type_Id,
	values:        []Operand,
	field_indices: []u32,
	conversions:   []Plan_Id,
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
}
Bounds_Plan :: struct {
	kind:     Bounds_Kind,
	operands: []Operand,
	policy:   Check_Policy,
	helper:   Entity_Id,
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
	operand: Operand,
	test:    Optional_Test,
	values:  []Operand,
	failure: Plan_Id,
}
Context_Plan :: struct {
	parent: Plan_Id,
	scope:  Scope_Id,
	value:  Operand,
	copy:   bool,
}
Plan :: union {
	Conversion_Plan,
	Place_Plan,
	Call_Plan,
	Builtin_Plan,
	Aggregate_Plan,
	Assignment_Plan,
	Bounds_Plan,
	Union_Plan,
	Exit_Plan,
	Propagation_Plan,
	Context_Plan,
	Typeid_Plan,
	Type_Info_Plan,
	Switch_Plan,
}
Switch_Plan :: struct {
	tag:         Entity_Id,
	comparisons: []Plan_Id,
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
	convention:          types.Calling_Convention,
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
	size, alignment: i64,
	flags:           u32,
	descriptor:      Const_Id,
	symbol:          Symbol_Id,
}
Runtime_Requirements :: struct {
	schema_entities, helper_entities: []Entity_Id,
	dependencies:                     []Dependency,
	type_info:                        []Type_Info_Entry,
	type_info_type:                   types.Type_Id,
	type_info_parameters_type:        types.Type_Id,
	enum_members:                     []Enum_Type_Members,
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
}

// The returned row is a copy; its referenced plans and constants remain borrowed.
expression_info :: proc(program: ^Checked_Program, view: View_Id, node: syntax.Node_Index) -> (info: Expression_Info, ok: bool) #optional_ok {
	if program == nil || node == 0 { return }
	typed := table_entry(program.typed_views, view)
	if typed == nil || node < typed.first_node { return }
	index := int(node - typed.first_node)
	nodes := typed.nodes
	count := len(nodes.types)
	assert(len(nodes.constants) == count && len(nodes.modes) == count && len(nodes.entities) == count)
	assert(len(nodes.plans) == count && len(nodes.scopes) == count && len(nodes.states) == count)
	if index < 0 || index >= count { return }
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
