package analysis

import "base:runtime"
import "core:fmt"
import "core:math/big"
import "oc:check"
import "oc:syntax"
import "oc:types"

Site :: check.Expression_Ref

// A global, a `@(static)`, a `@(thread_local)`, or a struct field shared by every value of the struct.
Location :: struct {
	entity: check.Entity_Id,
	type:   types.Type_Id,
	field:  u32,
}

Atomic_Arm :: struct {
	branch: syntax.Node_Index,
	arm:    i32,
}

Atomic_Place :: struct {
	loop:     syntax.Node_Index,
	arms:     []Atomic_Arm,
	deferred: bool,
	discards: bool,
}

Placed_Call :: struct {
	call:  syntax.Node_Index,
	place: Atomic_Place,
}

Atomic_Procedure :: struct {
	ready:           bool,
	view:            check.View_Id,
	has_seq_cst:     bool,
	acquires:        [dynamic]syntax.Node_Index,
	releases:        [dynamic]syntax.Node_Index,
	signal_acquires: [dynamic]syntax.Node_Index,
	signal_releases: [dynamic]syntax.Node_Index,
	places:          [dynamic]Placed_Call,
}

Atomic_Uses :: struct {
	first, load, store:         Site,
	asks_acquire, asks_release: Site,
	smallest, largest:          Site,
	acquires, releases:         bool,
	escaped:                    bool,
}

// One atomic builtin, fence or futex call, within the procedure it appears in.
Atomic_Call :: struct {
	call:      Site,
	kind:      check.Builtin_Kind,
	futex:     check.Futex_Kind,
	procedure: Procedure_Id,
	tuple:     bool,
}

Atomic_Site :: struct {
	location:  Location,
	call:      Site,
	procedure: Procedure_Id,
}

Atomic_Access :: struct {
	location:  Location,
	call:      Site,
	procedure: Procedure_Id,
	store:     bool,
	seq_cst:   bool,
}

Atomic_Local :: struct {
	procedure:        Procedure_Id,
	count, addressed: i32,
	first:            Site,
}

Atomic_At :: struct {
	node: syntax.Node_Index,
	arms: []Atomic_Arm,
}

Atomic_Object :: struct {
	root: check.Entity_Id,
	path: string,
}

Atomic_Sync :: struct {
	call:     syntax.Node_Index,
	arms:     []Atomic_Arm,
	object:   Atomic_Object,
	order:    check.Atomic_Order,
	shared:   bool,
	deferred: bool,
}

Atomic_Exit :: struct {
	syncs: int,
	arms:  []Atomic_Arm,
}

Atomic_Effect :: struct {
	param:  i32,
	object: Atomic_Object,
	order:  check.Atomic_Order,
	shared: bool,
}

Atomic_Report_Kind :: enum u8 {
	Release,
	Acquire,
	Weak_Ignored,
	Wake_Early,
	Local,
	Volatile,
	Thread_Local,
	Store_Load,
	Mixed_Size,
}

Atomic_Report :: struct {
	kind:  Atomic_Report_Kind,
	site:  Site,
	other: Site,
}

// Every table is indexed by Procedure_Id; sites are Expression_Refs of the checked program.
Atomics :: struct {
	run:        ^Run,
	graph:      ^Call_Graph,
	program:    ^check.Checked_Program,
	allocator:  runtime.Allocator,
	procedures: []Atomic_Procedure,
	effects:    [][]Atomic_Effect,
	inferred:   []bool,
	uses:       map[Location]Atomic_Uses,
	locations:  [dynamic]Location,
	reports:    [dynamic]Atomic_Report,
	calls:      [dynamic]Atomic_Call,
	call_index: map[Site]int,
	created:    [dynamic]Procedure_Id,
	stamp:      []u32,
	stamp_mark: u32,
	queue:      [dynamic]Procedure_Id,
}

atomic_ast :: proc(a: ^Atomics, view: check.View_Id) -> ^syntax.Ast {
	return a.program.files[a.program.typed_views[view].file].ast
}

atomic_file :: proc(a: ^Atomics, view: check.View_Id) -> check.File_Id {
	return a.program.typed_views[view].file
}

atomic_info :: proc(a: ^Atomics, view: check.View_Id, node: syntax.Node_Index) -> check.Expression_Info {
	return check.expression_info(a.program, view, node)
}

atomic_unparen :: proc(ast: ^syntax.Ast, node: syntax.Node_Index) -> syntax.Node_Index {
	node := node
	for node != 0 && ast.nodes[node].kind == .Paren_Expr { node = syntax.node_payload(ast, node, syntax.Paren_Expr).expr }
	return node
}

atomic_span :: proc(a: ^Atomics, site: Site) -> check.Source_Span {
	node := atomic_ast(a, site.view).nodes[site.node]
	return {atomic_file(a, site.view), node.start, node.end}
}

atomic_source :: proc(a: ^Atomics, view: check.View_Id) -> []byte {
	return a.program.files[atomic_file(a, view)].source
}

atomic_text :: proc(a: ^Atomics, site: Site) -> string {
	return check.render_expression(atomic_ast(a, site.view), atomic_source(a, site.view), site.node, a.allocator)
}

// Matches token_pos_cmp, including positions in different files.
atomic_before :: proc(a: ^Atomics, x, y: Site) -> bool {
	fx, fy := atomic_file(a, x.view), atomic_file(a, y.view)
	offset_x, offset_y := atomic_ast(a, x.view).nodes[x.node].start, atomic_ast(a, y.view).nodes[y.node].start
	if offset_x != offset_y { return offset_x < offset_y }
	line_x, column_x := syntax.line_col(a.program.files[fx].lines, offset_x)
	line_y, column_y := syntax.line_col(a.program.files[fy].lines, offset_y)
	if line_x != line_y { return line_x < line_y }
	if column_x != column_y { return column_x < column_y }
	return fx != fy && a.program.files[fx].path < a.program.files[fy].path
}

atomic_same_place :: proc(a: ^Atomics, x, y: Site) -> bool {
	return atomic_file(a, x.view) == atomic_file(a, y.view) && atomic_ast(a, x.view).nodes[x.node].start == atomic_ast(a, y.view).nodes[y.node].start
}

atomic_position :: proc(a: ^Atomics, site: Site) -> string {
	file := &a.program.files[atomic_file(a, site.view)]
	line, column := syntax.line_col(file.lines, atomic_ast(a, site.view).nodes[site.node].start)
	return fmt.aprintf("%s(%d:%d)", file.display_path, line, column, allocator = a.allocator)
}

atomic_analyzed :: proc(a: ^Atomics, site: Site) -> bool {
	return .Atomic in atomic_ast(a, site.view).analysis
}

atomic_acquires :: proc(order: check.Atomic_Order) -> bool {
	return order == .Consume || order == .Acquire || order == .Acq_Rel || order == .Seq_Cst
}

atomic_releases :: proc(order: check.Atomic_Order) -> bool {
	return order == .Release || order == .Acq_Rel || order == .Seq_Cst
}

// The constant memory order an argument names.
atomic_order_of :: proc(a: ^Atomics, view: check.View_Id, node: syntax.Node_Index) -> check.Atomic_Order {
	constant := check.constant(a.program, atomic_info(a, view, node).constant)
	if constant == nil { return .Seq_Cst }
	if value, ok := constant.value.(big.Int); ok {
		number, _ := big.int_get_i64(&value)
		return check.Atomic_Order(number)
	}
	return .Seq_Cst
}

// A total order on locations, in place of the official pointer order: declaration source first, then type and field.
atomic_location_key :: proc(a: ^Atomics, location: Location) -> [4]u32 {
	if location.entity != 0 {
		declaration := a.program.entities[location.entity].declaration
		start := u32(0)
		if declaration.node != 0 { start = a.program.files[declaration.file].ast.nodes[declaration.node].start }
		return {u32(declaration.file), start, u32(location.entity), 0}
	}
	return {max(u32), u32(location.type), location.field, 0}
}

atomic_location_less :: proc(a: ^Atomics, x, y: Location) -> bool {
	kx, ky := atomic_location_key(a, x), atomic_location_key(a, y)
	for index in 0 ..< 4 {
		if kx[index] != ky[index] { return kx[index] < ky[index] }
	}
	return false
}
