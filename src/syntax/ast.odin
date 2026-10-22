// Index-based AST for the Odin grammar, with the node kinds and field meanings of core:odin/ast.
//
// Every node lives in `Ast.nodes` and is named by a `Node_Index`; variable-length children live in
// `Ast.extra` and are named by a `Node_Range`. Each payload is a tagged union member, because one
// array of tagged nodes gives one handle type and keeps creation order. Kinds that differ only by a
// keyword may share a payload struct, since the explicit `Node_Kind` tells them apart.
// Operators are stored as `Token`, other keywords and brackets as `u32` offsets, and names and
// literals as `Node_Index` to `Ident` or `Basic_Lit` nodes. Index 0 is a reserved sentinel, so a zero
// handle means "none".
package syntax

import "core:fmt"
import "core:mem"
import "core:reflect"
import "core:strings"

Node_Index :: distinct u32

Node_Range :: struct {
	first: u32,
	count: u32,
}

Node_Flag :: enum u8 {
	Bounds_Check,
	No_Bounds_Check,
	Type_Assert,
	No_Type_Assert,
}
Node_Flags :: distinct bit_set[Node_Flag;u8]

Node :: struct {
	kind:    Node_Kind,
	flags:   Node_Flags,
	start:   u32,
	end:     u32,
	payload: Node_Payload,
}

Ast :: struct {
	nodes:            [dynamic]Node,
	extra:            [dynamic]Node_Index,
	root:             Node_Index,
	// Set by a failed append; `parse_file` turns it into a Parse_Error so the parse fails.
	allocation_error: mem.Allocator_Error,
}

ast_init :: proc(ast: ^Ast, allocator := context.allocator) {
	ast.nodes = make([dynamic]Node, 1, 256, allocator)
	ast.extra = make([dynamic]Node_Index, 0, 256, allocator)
	ast.root = 0
}

ast_destroy :: proc(ast: ^Ast) {
	delete(ast.nodes)
	delete(ast.extra)
	ast^ = {}
}

ast_add_node :: proc(ast: ^Ast, kind: Node_Kind, start, end: u32, payload: Node_Payload) -> Node_Index {
	if _, err := append(&ast.nodes, Node{kind = kind, start = start, end = end, payload = payload}); err != nil {
		ast.allocation_error = err
		return 0
	}
	return Node_Index(len(ast.nodes) - 1)
}

ast_add_list :: proc(ast: ^Ast, children: []Node_Index) -> Node_Range {
	range := Node_Range {
		first = u32(len(ast.extra)),
		count = u32(len(children)),
	}
	if _, err := append(&ast.extra, ..children); err != nil {
		ast.allocation_error = err
		return {}
	}
	return range
}

node_kind :: proc(ast: ^Ast, index: Node_Index) -> Node_Kind {
	return ast.nodes[index].kind
}

node_span :: proc(ast: ^Ast, index: Node_Index) -> (start, end: u32) {
	node := ast.nodes[index]
	return node.start, node.end
}

node_payload :: proc(ast: ^Ast, index: Node_Index, $Payload: typeid) -> Payload {
	return ast.nodes[index].payload.(Payload)
}

node_list :: proc(ast: ^Ast, range: Node_Range) -> []Node_Index {
	return ast.extra[range.first:][:range.count]
}

// ast_dump writes the tree under `ast.root`, one node per line, children indented two spaces per
// level. Scalar fields are printed on the node line in declaration order; text is the source slice.
ast_dump :: proc(ast: ^Ast, source: []byte, builder: ^strings.Builder) {
	if ast.root != 0 {
		dump_node(ast, source, builder, ast.root, "", 0)
	}
}

@(private = "file")
dump_node :: proc(ast: ^Ast, source: []byte, builder: ^strings.Builder, index: Node_Index, label: string, depth: int) {
	node := &ast.nodes[index]
	for _ in 0 ..< depth {
		strings.write_string(builder, "  ")
	}
	if label != "" {
		fmt.sbprintf(builder, "%s: ", label)
	}
	fmt.sbprintf(builder, "%v %d..%d", node.kind, node.start, node.end)
	if text := string(source[node.start:node.end]); len(text) <= 40 && strings.index_byte(text, '\n') < 0 {
		fmt.sbprintf(builder, " %q", text)
	}
	if node.flags != {} {
		fmt.sbprintf(builder, " flags=%v", node.flags)
	}

	variant := reflect.get_union_variant(any{rawptr(&node.payload), typeid_of(Node_Payload)})
	fields := reflect.struct_fields_zipped(variant.id)
	for field in fields {
		value := reflect.struct_field_value(variant, field)
		switch field.type.id {
		case typeid_of(Node_Index), typeid_of(Node_Range):
		case typeid_of(Token):
			fmt.sbprintf(builder, " %s=%v", field.name, value.(Token).kind)
		case:
			fmt.sbprintf(builder, " %s=%v", field.name, value)
		}
	}
	strings.write_byte(builder, '\n')

	for field in fields {
		value := reflect.struct_field_value(variant, field)
		switch field.type.id {
		case typeid_of(Node_Index):
			if child := value.(Node_Index); child != 0 {
				dump_node(ast, source, builder, child, field.name, depth + 1)
			}
		case typeid_of(Node_Range):
			for child, position in node_list(ast, value.(Node_Range)) {
				dump_node(ast, source, builder, child, fmt.tprintf("%s[%d]", field.name, position), depth + 1)
			}
		}
	}
}

Proc_Tag :: enum u8 {
	Bounds_Check,
	No_Bounds_Check,
	Optional_Ok,
	Optional_Allocator_Error,
}
Proc_Tags :: distinct bit_set[Proc_Tag;u8]

Proc_Inlining :: enum u8 {
	None,
	Inline,
	No_Inline,
}

Proc_Tailing :: enum u8 {
	None,
	Must_Tail,
}

Union_Type_Kind :: enum u8 {
	Normal,
	Maybe,
	No_Nil,
	Shared_Nil,
}

Struct_Flag :: enum u8 {
	Packed,
	Raw_Union,
	No_Copy,
	All_Or_None,
	Simple,
}
Struct_Flags :: distinct bit_set[Struct_Flag;u8]

Field_Flag :: enum u16 {
	Ellipsis,
	Using,
	No_Alias,
	C_Vararg,
	Const,
	Any_Int,
	Subtype,
	By_Ptr,
	No_Broadcast,
	No_Capture,
	Results,
	Tags,
	Default_Parameters,
	Typeid_Token,
}
Field_Flags :: distinct bit_set[Field_Flag;u16]

Asm_Memory_Operand_Kind :: enum u8 {
	Default,
	Pre,
	Post,
}

Bad_Expr :: struct {}

Ident :: struct {}

Implicit :: struct {
	kind: Token_Kind,
}

Undef :: struct {}

Basic_Lit :: struct {
	kind: Token_Kind,
}

Basic_Directive :: struct {}

Ellipsis :: struct {
	op:   Token_Kind,
	expr: Node_Index,
}

Proc_Lit :: struct {
	type:          Node_Index,
	body:          Node_Index, // 0 for foreign procedures
	tags:          Proc_Tags,
	inlining:      Proc_Inlining,
	tailing:       Proc_Tailing,
	where_pos:     u32,
	where_clauses: Node_Range,
}

Comp_Lit :: struct {
	type:  Node_Index,
	open:  u32,
	elems: Node_Range,
	close: u32,
	tag:   Node_Index,
}

Tag_Expr :: struct {
	op:   Token,
	expr: Node_Index,
}

Unary_Expr :: struct {
	op:   Token,
	expr: Node_Index,
}

Binary_Expr :: struct {
	left:  Node_Index,
	op:    Token,
	right: Node_Index,
}

Paren_Expr :: struct {
	open:  u32,
	expr:  Node_Index,
	close: u32,
}

Selector_Expr :: struct {
	expr:  Node_Index,
	op:    Token,
	field: Node_Index,
}

Implicit_Selector_Expr :: struct {
	field: Node_Index,
}

Selector_Call_Expr :: struct {
	expr:          Node_Index,
	call:          Node_Index,
	modified_call: bool,
}

Index_Expr :: struct {
	expr:  Node_Index,
	open:  u32,
	index: Node_Index,
	close: u32,
}

Deref_Expr :: struct {
	expr: Node_Index,
	op:   Token,
}

Slice_Expr :: struct {
	expr:     Node_Index,
	open:     u32,
	low:      Node_Index,
	interval: Token,
	high:     Node_Index,
	close:    u32,
}

Matrix_Index_Expr :: struct {
	expr:         Node_Index,
	open:         u32,
	row_index:    Node_Index,
	column_index: Node_Index,
	close:        u32,
}

Call_Expr :: struct {
	inlining: Proc_Inlining,
	tailing:  Proc_Tailing,
	expr:     Node_Index,
	open:     u32,
	args:     Node_Range,
	ellipsis: Token,
	close:    u32,
}

Field_Value :: struct {
	field: Node_Index,
	sep:   u32,
	value: Node_Index,
}

Ternary_Expr :: struct {
	x:    Node_Index,
	op1:  Token,
	cond: Node_Index,
	op2:  Token,
	y:    Node_Index,
}

Or_Else_Expr :: struct {
	x:     Node_Index,
	token: Token,
	y:     Node_Index,
}

Or_Return_Expr :: struct {
	expr:  Node_Index,
	token: Token,
}

Or_Branch_Expr :: struct {
	expr:  Node_Index,
	token: Token,
	label: Node_Index,
}

Type_Assertion :: struct {
	expr:  Node_Index,
	dot:   u32,
	open:  u32,
	type:  Node_Index,
	close: u32,
}

Type_Cast :: struct {
	token: Token,
	open:  u32,
	type:  Node_Index,
	close: u32,
	expr:  Node_Index,
}

Auto_Cast :: struct {
	op:   Token,
	expr: Node_Index,
}

Proc_Group :: struct {
	proc_pos: u32,
	open:     u32,
	args:     Node_Range,
	close:    u32,
}

Typeid_Type :: struct {
	specialization: Node_Index,
}

Helper_Type :: struct {
	type: Node_Index,
}

Distinct_Type :: struct {
	type: Node_Index,
}

Poly_Type :: struct {
	dollar:         u32,
	type:           Node_Index,
	specialization: Node_Index,
}

Proc_Type :: struct {
	proc_pos:           u32,
	calling_convention: Node_Index, // Basic_Lit string, or 0 for the default
	foreign_default:    bool, // in a foreign block without an explicit convention
	params:             Node_Index,
	arrow:              u32,
	results:            Node_Index,
	tags:               Proc_Tags,
	generic:            bool,
	diverging:          bool,
}

Pointer_Type :: struct {
	tag:     Node_Index,
	pointer: u32,
	elem:    Node_Index,
}

Multi_Pointer_Type :: struct {
	open:    u32,
	pointer: u32,
	close:   u32,
	elem:    Node_Index,
}

Array_Type :: struct {
	tag:   Node_Index,
	open:  u32,
	len:   Node_Index,
	close: u32,
	elem:  Node_Index,
}

Dynamic_Array_Type :: struct {
	tag:         Node_Index,
	open:        u32,
	dynamic_pos: u32,
	close:       u32,
	elem:        Node_Index,
}

Fixed_Capacity_Dynamic_Array_Type :: struct {
	tag:         Node_Index,
	open:        u32,
	dynamic_pos: u32,
	capacity:    Node_Index,
	close:       u32,
	elem:        Node_Index,
}

Struct_Type :: struct {
	tok_pos:         u32,
	poly_params:     Node_Index,
	align:           Node_Index,
	min_field_align: Node_Index,
	max_field_align: Node_Index,
	where_pos:       u32,
	where_clauses:   Node_Range,
	fields:          Node_Index,
	name_count:      u32,
	flags:           Struct_Flags,
}

Union_Type :: struct {
	tok_pos:       u32,
	poly_params:   Node_Index,
	align:         Node_Index,
	kind:          Union_Type_Kind,
	where_pos:     u32,
	where_clauses: Node_Range,
	variants:      Node_Range,
}

Enum_Type :: struct {
	tok_pos:   u32,
	base_type: Node_Index,
	open:      u32,
	fields:    Node_Range,
	close:     u32,
	is_using:  bool,
}

Bit_Set_Type :: struct {
	tok_pos:    u32,
	open:       u32,
	elem:       Node_Index,
	underlying: Node_Index,
	close:      u32,
}

Map_Type :: struct {
	tok_pos: u32,
	key:     Node_Index,
	value:   Node_Index,
}

Relative_Type :: struct {
	tag:  Node_Index,
	type: Node_Index,
}

Matrix_Type :: struct {
	tok_pos:      u32,
	row_count:    Node_Index,
	column_count: Node_Index,
	elem:         Node_Index,
	tag:          Node_Index,
}

Bit_Field_Type :: struct {
	tok_pos:      u32,
	backing_type: Node_Index,
	open:         u32,
	fields:       Node_Range,
	close:        u32,
}

Bad_Stmt :: struct {}

Empty_Stmt :: struct {
	semicolon: u32,
}

Expr_Stmt :: struct {
	expr: Node_Index,
}

Tag_Stmt :: struct {
	op:   Token,
	stmt: Node_Index,
}

Assign_Stmt :: struct {
	lhs: Node_Range,
	op:  Token,
	rhs: Node_Range,
}

Block_Stmt :: struct {
	label:   Node_Index,
	open:    u32,
	stmts:   Node_Range,
	close:   u32,
	uses_do: bool,
}

If_Stmt :: struct {
	label:     Node_Index,
	if_pos:    u32,
	init:      Node_Index,
	cond:      Node_Index,
	body:      Node_Index,
	else_pos:  u32,
	else_stmt: Node_Index,
}

When_Stmt :: struct {
	when_pos:  u32,
	cond:      Node_Index,
	body:      Node_Index,
	else_stmt: Node_Index,
}

Return_Stmt :: struct {
	results: Node_Range,
}

Defer_Stmt :: struct {
	stmt: Node_Index,
}

For_Stmt :: struct {
	label:   Node_Index,
	for_pos: u32,
	init:    Node_Index,
	cond:    Node_Index,
	post:    Node_Index,
	body:    Node_Index,
}

Range_Stmt :: struct {
	label:   Node_Index,
	init:    Node_Index,
	for_pos: u32,
	vals:    Node_Range,
	in_pos:  u32,
	expr:    Node_Index,
	body:    Node_Index,
	reverse: bool,
}

Unroll_Range_Stmt :: struct {
	label:      Node_Index,
	unroll_pos: u32,
	args:       Node_Range,
	for_pos:    u32,
	val0:       Node_Index,
	val1:       Node_Index,
	in_pos:     u32,
	expr:       Node_Index,
	body:       Node_Index,
}

Case_Clause :: struct {
	case_pos:   u32,
	list:       Node_Range,
	terminator: Token,
	body:       Node_Range,
}

Switch_Stmt :: struct {
	label:      Node_Index,
	switch_pos: u32,
	init:       Node_Index,
	cond:       Node_Index,
	body:       Node_Index,
	partial:    bool,
}

Type_Switch_Stmt :: struct {
	label:      Node_Index,
	switch_pos: u32,
	tag:        Node_Index,
	expr:       Node_Index,
	body:       Node_Index,
	partial:    bool,
}

Branch_Stmt :: struct {
	token: Token,
	label: Node_Index,
}

Using_Stmt :: struct {
	list: Node_Range,
}

Bad_Decl :: struct {}

Value_Decl :: struct {
	attributes: Node_Range,
	names:      Node_Range,
	type:       Node_Index,
	values:     Node_Range,
	is_using:   bool,
	is_mutable: bool,
}

Package_Decl :: struct {
	package_pos: u32,
	name:        Node_Index,
}

Import_Decl :: struct {
	attributes: Node_Range,
	is_using:   bool,
	import_pos: u32,
	name:       Node_Index,
	relpath:    Node_Index,
}

Foreign_Block_Decl :: struct {
	attributes:      Node_Range,
	foreign_pos:     u32,
	foreign_library: Node_Index,
	body:            Node_Index,
}

Foreign_Import_Decl :: struct {
	attributes:      Node_Range,
	foreign_pos:     u32,
	import_pos:      u32,
	name:            Node_Index,
	collection_name: Token,
	fullpaths:       Node_Range,
}

File :: struct {
	tags:         Node_Range,
	package_decl: Node_Index,
	decls:        Node_Range,
}

File_Tag :: struct {}

Attribute :: struct {
	open:  u32,
	elems: Node_Range,
	close: u32,
}

Field :: struct {
	names:         Node_Range,
	type:          Node_Index,
	default_value: Node_Index,
	tag:           Node_Index,
	flags:         Field_Flags,
}

Field_List :: struct {
	open:  u32,
	list:  Node_Range,
	close: u32,
}

Bit_Field_Field :: struct {
	name:     Node_Index,
	type:     Node_Index,
	bit_size: Node_Index,
}

Asm_Template :: struct {
	tok_pos:      u32,
	type:         Node_Index,
	specs:        Node_Range,
	clobbers:     Node_Range,
	instructions: Node_Range,
}

Asm_Spec :: struct {
	name:       Node_Index,
	tied_name:  Node_Index,
	type:       Node_Index,
	value:      Node_Index,
	directives: Node_Range,
}

Asm_Register :: struct {
	name: Node_Index,
	flag: Node_Index,
}

Asm_Clobber :: struct {
	name:  Node_Index,
	value: Node_Index,
}

Asm_Label :: struct {
	name: Node_Index,
}

Asm_Label_Decl :: struct {
	label: Node_Index,
}

Asm_Instruction :: struct {
	name:     Node_Index,
	operands: Node_Range,
}

Asm_Memory_Operand :: struct {
	kind:             Asm_Memory_Operand_Kind,
	open:             u32,
	segment_override: Node_Index,
	base:             Node_Index,
	index_op:         Token_Kind,
	index:            Node_Index,
	scale_op:         Token_Kind,
	scale:            Node_Index,
	disp_op:          Token_Kind,
	disp:             Node_Index,
	close:            u32,
	type:             Node_Index,
}

Asm_Register_Group :: struct {
	open:        u32,
	registers:   Node_Range,
	range_token: Token_Kind,
	close:       u32,
	type:        Node_Index,
}

Asm_Directive :: struct {
	name:     Node_Index,
	operands: Node_Range,
}

Node_Kind :: enum u8 {
	Invalid,
	Bad_Expr,
	Ident,
	Implicit,
	Undef,
	Basic_Lit,
	Basic_Directive,
	Ellipsis,
	Proc_Lit,
	Comp_Lit,
	Tag_Expr,
	Unary_Expr,
	Binary_Expr,
	Paren_Expr,
	Selector_Expr,
	Implicit_Selector_Expr,
	Selector_Call_Expr,
	Index_Expr,
	Deref_Expr,
	Slice_Expr,
	Matrix_Index_Expr,
	Call_Expr,
	Field_Value,
	Ternary_If_Expr,
	Ternary_When_Expr,
	Or_Else_Expr,
	Or_Return_Expr,
	Or_Branch_Expr,
	Type_Assertion,
	Type_Cast,
	Auto_Cast,
	Proc_Group,
	Typeid_Type,
	Helper_Type,
	Distinct_Type,
	Poly_Type,
	Proc_Type,
	Pointer_Type,
	Multi_Pointer_Type,
	Array_Type,
	Dynamic_Array_Type,
	Fixed_Capacity_Dynamic_Array_Type,
	Struct_Type,
	Union_Type,
	Enum_Type,
	Bit_Set_Type,
	Map_Type,
	Relative_Type,
	Matrix_Type,
	Bit_Field_Type,
	Bad_Stmt,
	Empty_Stmt,
	Expr_Stmt,
	Tag_Stmt,
	Assign_Stmt,
	Block_Stmt,
	If_Stmt,
	When_Stmt,
	Return_Stmt,
	Defer_Stmt,
	For_Stmt,
	Range_Stmt,
	Unroll_Range_Stmt,
	Case_Clause,
	Switch_Stmt,
	Type_Switch_Stmt,
	Branch_Stmt,
	Using_Stmt,
	Bad_Decl,
	Value_Decl,
	Package_Decl,
	Import_Decl,
	Foreign_Block_Decl,
	Foreign_Import_Decl,
	File,
	File_Tag,
	Attribute,
	Field,
	Field_List,
	Bit_Field_Field,
	Asm_Template,
	Asm_Spec,
	Asm_Register,
	Asm_Clobber,
	Asm_Label,
	Asm_Label_Decl,
	Asm_Instruction,
	Asm_Memory_Operand,
	Asm_Register_Group,
	Asm_Directive,
}

// Ternary_When_Expr shares Ternary_Expr with Ternary_If_Expr: the kind tells them apart.
Node_Payload :: union {
	Bad_Expr,
	Ident,
	Implicit,
	Undef,
	Basic_Lit,
	Basic_Directive,
	Ellipsis,
	Proc_Lit,
	Comp_Lit,
	Tag_Expr,
	Unary_Expr,
	Binary_Expr,
	Paren_Expr,
	Selector_Expr,
	Implicit_Selector_Expr,
	Selector_Call_Expr,
	Index_Expr,
	Deref_Expr,
	Slice_Expr,
	Matrix_Index_Expr,
	Call_Expr,
	Field_Value,
	Ternary_Expr,
	Or_Else_Expr,
	Or_Return_Expr,
	Or_Branch_Expr,
	Type_Assertion,
	Type_Cast,
	Auto_Cast,
	Proc_Group,
	Typeid_Type,
	Helper_Type,
	Distinct_Type,
	Poly_Type,
	Proc_Type,
	Pointer_Type,
	Multi_Pointer_Type,
	Array_Type,
	Dynamic_Array_Type,
	Fixed_Capacity_Dynamic_Array_Type,
	Struct_Type,
	Union_Type,
	Enum_Type,
	Bit_Set_Type,
	Map_Type,
	Relative_Type,
	Matrix_Type,
	Bit_Field_Type,
	Bad_Stmt,
	Empty_Stmt,
	Expr_Stmt,
	Tag_Stmt,
	Assign_Stmt,
	Block_Stmt,
	If_Stmt,
	When_Stmt,
	Return_Stmt,
	Defer_Stmt,
	For_Stmt,
	Range_Stmt,
	Unroll_Range_Stmt,
	Case_Clause,
	Switch_Stmt,
	Type_Switch_Stmt,
	Branch_Stmt,
	Using_Stmt,
	Bad_Decl,
	Value_Decl,
	Package_Decl,
	Import_Decl,
	Foreign_Block_Decl,
	Foreign_Import_Decl,
	File,
	File_Tag,
	Attribute,
	Field,
	Field_List,
	Bit_Field_Field,
	Asm_Template,
	Asm_Spec,
	Asm_Register,
	Asm_Clobber,
	Asm_Label,
	Asm_Label_Decl,
	Asm_Instruction,
	Asm_Memory_Operand,
	Asm_Register_Group,
	Asm_Directive,
}
