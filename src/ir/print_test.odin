package ir

import "core:strings"
import "core:testing"

@(test)
print_module_writes_golden_text :: proc(t: ^testing.T) {
	module: Module
	testing.expect(t, module_init(&module) == nil, "module_init failed")
	defer module_destroy(&module)

	append(&module.globals, Global{name = "answer", size = 8, align = 8, mutable = true, bytes = []byte{42, 0, 0, 0, 0, 0, 0, 0}})
	append(&module.globals, Global{name = "table_ptr", size = 8, align = 8, bytes = []byte{0, 0, 0, 0, 0, 0, 0, 0}, relocs = {{target = {.Function, 0}}}})
	append(&module.externs, Extern{name = "write"})

	fn, make_err := function_make(context.allocator, 0, "main.add", 0)
	testing.expect(t, make_err == nil, "function_make failed")
	append(&module.functions, fn)
	append(
		&fn.signatures,
		Signature{cc = .C, params = {{type = .I64, attr = .Direct}, {type = .Bool, attr = .Direct, ext = .Zero}}, results = {{type = .I64}}},
	)
	_, table_ok := add_table(fn, []i64{1, -2})
	testing.expect(t, table_ok, "add_table failed")
	append(&fn.blobs, Data_Blob{bytes = []byte{'h', 'i', 0}, align = 1})
	append(&fn.blobs, Data_Blob{bytes = []byte{0, 0, 0, 0, 0, 0, 0, 0}, align = 8, relocs = {{target = {.Local_Blob, 0}, addend = 4}}})

	start := add_node(fn, .Start, .Tuple)
	ctrl := add_node(fn, .Proj, .Control, {start}, Node_Data{index = 0})
	mem := add_node(fn, .Proj, .Memory, {start}, Node_Data{index = 1})
	param_0 := add_node(fn, .Proj, .I64, {start}, Node_Data{index = 2})
	_ = add_node(fn, .Proj, .Bool, {start}, Node_Data{index = 3}, {.Cold})
	one := add_node(fn, .Const_Int, .I64, nil, Node_Data{int_value = 1})
	sum := add_node(fn, .Add, .I64, {param_0, one})
	_ = add_node(fn, .Const_Float, .F64, nil, Node_Data{float_bits = 0x3ff0_0000_0000_0000})
	answer := add_node(fn, .Symbol_Addr, .Ptr, nil, Node_Data{symbol = {.Global, 0}})
	stored := add_node(fn, .Store, .Memory, {ctrl, mem, answer, sum}, Node_Data{access = {align_log2 = 3}})
	_ = add_node(fn, .Load, .I64, {ctrl, stored, answer}, Node_Data{access = {align_log2 = 3}})
	atomic := add_node(fn, .Atomic_Rmw, .Tuple, {ctrl, stored, answer, sum}, Node_Data{access = {align_log2 = 3, order = .Seq_Cst, rmw = .Add}})
	atomic_mem := add_node(fn, .Proj, .Memory, {atomic}, Node_Data{index = 0})
	ret := add_node(fn, .Return, .None, {ctrl, atomic_mem, sum})
	_ = add_node(fn, .Stop, .None, {ret})

	builder: strings.Builder
	strings.builder_init(&builder)
	defer strings.builder_destroy(&builder)
	testing.expect_value(t, print_module(strings.to_writer(&builder), &module), nil)

	expected := `global g0 "answer" size 8 align 8 mut bytes 2a00000000000000
global g1 "table_ptr" size 8 align 8 bytes 0000000000000000
  reloc 0 -> f0
extern e0 "write"
func f0 "main.add" sig=s0 {
  sig s0 cc c (i64, bool:zext) -> (i64)
  table t0 [1, -2]
  blob b0 align 1 bytes 686900
  blob b1 align 8 bytes 0000000000000000
    reloc 0 -> b0 + 4
  n1 = start.tuple
  n2 = proj.ctrl n1 index=0
  n3 = proj.mem n1 index=1
  n4 = proj.i64 n1 index=2
  n5 = proj.bool n1 index=3 cold
  n6 = const_int.i64 value=1
  n7 = add.i64 n4, n6
  n8 = const_float.f64 bits=0x3ff0000000000000
  n9 = symbol_addr.ptr sym=g0
  n10 = store.mem n2, n3, n9, n7 align=8 order=plain
  n11 = load.i64 n2, n10, n9 align=8 order=plain
  n12 = atomic_rmw.tuple n2, n10, n9, n7 align=8 order=seq_cst op=add
  n13 = proj.mem n12 index=0
  n14 = return.none n2, n13, n7
  n15 = stop.none n14
}
`
	testing.expect_value(t, strings.to_string(builder), expected)
}
