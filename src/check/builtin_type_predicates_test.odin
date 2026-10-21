package check

import "core:testing"
import "oc:syntax"
import "oc:types"

// Probe table for the type_is_*/type_has_nil predicates, recorded against the
// official compiler (ODIN_ROOT=/home/su3h7am/Projects/Odin). Each entry pins
// the official answer, including the traps: type_is_string is flag-based and
// true for cstring, string16 and cstring16; type_is_named is true for every
// basic type with no unwrapping; non-type and non-matrix arguments are hard
// errors; subtype is identical-only on concrete types; matrix elements exclude
// quaternion and bool.
@(test)
type_predicates_fold_to_official_bools :: proc(t: ^testing.T) {
	source := transmute([]byte)string(
		`package sample
My_Int :: distinct int
My_Ptr :: distinct ^int
Pair :: struct { a: u8, b: i32 }
Empty :: struct {}
E :: enum { A, B }
Big :: enum { A, B, C }
BF :: bit_field u32 { x: u8 | 8, y: u8 | 8 }
U :: union { int, string }
U3 :: union { int, string, f32 }
row_major_plain :: type_is_matrix_row_major(matrix[2, 3]f32)
col_major_plain :: type_is_matrix_column_major(matrix[2, 3]f32)
row_major_tagged :: type_is_matrix_row_major(#row_major matrix[2, 3]f32)
col_major_tagged :: type_is_matrix_column_major(#row_major matrix[2, 3]f32)
matrix_yes :: type_is_matrix(matrix[2, 3]f32)
matrix_no :: type_is_matrix(int)
simd_yes :: type_is_simd_vector(#simd[4]f32)
simd_no :: type_is_simd_vector([4]f32)
fixedcap_yes :: type_is_fixed_capacity_dynamic_array([dynamic; 4]int)
fixedcap_no :: type_is_fixed_capacity_dynamic_array([dynamic]int)
bitfield_yes :: type_is_bit_field(BF)
bitfield_no :: type_is_bit_field(u32)
complex_yes :: type_is_complex(complex64)
complex_no :: type_is_complex(f32)
quat_yes :: type_is_quaternion(quaternion128)
quat_no :: type_is_quaternion(complex64)
rune_yes :: type_is_rune(rune)
rune_no :: type_is_rune(u8)
string_string :: type_is_string(string)
string_cstring :: type_is_string(cstring)
string_string16 :: type_is_string(string16)
string16_yes :: type_is_string16(string16)
string16_no :: type_is_string16(cstring16)
cstring_yes :: type_is_cstring(cstring)
cstring_no :: type_is_cstring(string)
cstring16_yes :: type_is_cstring16(cstring16)
cstring16_no :: type_is_cstring16(cstring)
any_yes :: type_is_any(any)
any_no :: type_is_any(int)
typeid_yes :: type_is_typeid(typeid)
typeid_no :: type_is_typeid(int)
named_distinct :: type_is_named(My_Int)
named_int :: type_is_named(int)
named_any :: type_is_named(any)
named_anon :: type_is_named(struct { x: int })
named_ptr :: type_is_named(^int)
deref_ptr :: type_is_dereferenceable(^int)
deref_named_ptr :: type_is_dereferenceable(My_Ptr)
deref_soa :: type_is_dereferenceable(^#soa[4]Point)
deref_rawptr :: type_is_dereferenceable(rawptr)
deref_multi :: type_is_dereferenceable([^]int)
deref_int :: type_is_dereferenceable(int)
indexable_array :: type_is_indexable([4]u8)
indexable_string :: type_is_indexable(string)
indexable_map :: type_is_indexable(map[string]int)
indexable_multi :: type_is_indexable([^]u8)
indexable_matrix :: type_is_indexable(matrix[2, 3]f32)
indexable_fixedcap :: type_is_indexable([dynamic; 4]int)
indexable_cstring :: type_is_indexable(cstring)
indexable_int :: type_is_indexable(int)
sliceable_slice :: type_is_sliceable([]u8)
sliceable_string :: type_is_sliceable(string)
sliceable_string16 :: type_is_sliceable(string16)
sliceable_array :: type_is_sliceable([4]u8)
sliceable_dyn :: type_is_sliceable([dynamic]u8)
sliceable_fixedcap :: type_is_sliceable([dynamic; 4]int)
sliceable_map :: type_is_sliceable(map[string]int)
sliceable_multi :: type_is_sliceable([^]u8)
sliceable_matrix :: type_is_sliceable(matrix[2, 3]f32)
nearly_float :: type_is_nearly_simple_compare(f32)
nearly_pair :: type_is_nearly_simple_compare(Pair)
nearly_string :: type_is_nearly_simple_compare(string)
mapkey_int :: type_is_valid_map_key(int)
mapkey_string :: type_is_valid_map_key(string)
mapkey_typeid :: type_is_valid_map_key(typeid)
mapkey_pair :: type_is_valid_map_key(Pair)
mapkey_any :: type_is_valid_map_key(any)
mapkey_slice :: type_is_valid_map_key([]u8)
mapkey_empty :: type_is_valid_map_key(Empty)
matrixelems_float :: type_is_valid_matrix_elements(f32)
matrixelems_rune :: type_is_valid_matrix_elements(rune)
matrixelems_complex :: type_is_valid_matrix_elements(complex64)
matrixelems_quat :: type_is_valid_matrix_elements(quaternion128)
matrixelems_bool :: type_is_valid_matrix_elements(bool)
matrixelems_string :: type_is_valid_matrix_elements(string)
endian_platform_int :: type_is_endian_platform(int)
endian_platform_le :: type_is_endian_platform(u16le)
endian_little_le :: type_is_endian_little(u16le)
endian_little_int :: type_is_endian_little(u16)
endian_little_ptr :: type_is_endian_little(^u8)
endian_little_struct :: type_is_endian_little(Pair)
endian_big_be :: type_is_endian_big(u16be)
endian_big_int :: type_is_endian_big(u16)
endian_platform_struct :: type_is_endian_platform(Pair)
hasnil_ptr :: type_has_nil(^int)
hasnil_any :: type_has_nil(any)
hasnil_union :: type_has_nil(U)
hasnil_slice :: type_has_nil([]int)
hasnil_enum :: type_has_nil(E)
hasnil_bitset :: type_has_nil(bit_set[E])
hasnil_map :: type_has_nil(map[string]int)
hasnil_cstring :: type_has_nil(cstring)
hasnil_typeid :: type_has_nil(typeid)
hasnil_int :: type_has_nil(int)
hasnil_struct :: type_has_nil(Pair)
hasnil_fixedcap :: type_has_nil([dynamic; 4]int)
hasnil_nonil :: type_has_nil(union #no_nil { int, string })
sub_same :: type_is_subtype_of(int, int)
sub_rune_int :: type_is_subtype_of(rune, int)
sub_named :: type_is_subtype_of(My_Int, int)
super_union :: type_is_superset_of(U3, U)
super_union_rev :: type_is_superset_of(U, U3)
super_enum :: type_is_superset_of(Big, E)
super_enum_rev :: type_is_superset_of(E, Big)
variant_yes :: type_is_variant_of(U, int)
variant_no :: type_is_variant_of(U, f32)
branch :: proc() -> int {
	code := 0
	if type_is_string(string) { code += 1 }
	when type_is_integer(int) { code += 2 }
	return code
}
bad_value :: type_is_string(42)
bad_nil :: type_is_string(nil)
bad_matrix :: type_is_matrix_row_major(int)
bad_variant :: type_is_variant_of(int, int)
bad_super :: type_is_superset_of(int, string)
bad_arity :: type_is_string(string, string)
Point :: struct { x, y: f32 }
`,
	)
	ast: syntax.Ast
	syntax.ast_init(&ast, context.allocator)
	defer syntax.ast_destroy(&ast)
	parser: syntax.Parser
	syntax.parser_init(&parser, &ast, source, context.allocator)
	defer syntax.parser_destroy(&parser)
	syntax.parse_file(&parser)
	if !testing.expectf(t, len(parser.errors) == 0 && len(parser.lex_errors) == 0, "%v", parser.errors) { return }

	store := types.init()
	defer types.destroy(&store)
	builtin_types := seed_builtin_types(&store)
	integer, word, boolean := builtin_types.int, builtin_types.uintptr, builtin_types.boolean
	pool: Constant_Pool
	if !testing.expect(t, constant_pool_init(&pool, context.allocator) == nil) { return }
	defer constant_pool_destroy(&pool)
	scopes: Scope_Store
	if !testing.expect(t, scope_store_init(&scopes, context.allocator) == nil) { return }
	defer scope_store_destroy(&scopes)
	universe, scope_error := scope_create(&scopes, 0, .Universal)
	if !testing.expect(t, scope_error == nil) { return }
	package_scope, package_error := scope_create(&scopes, universe, .Package)
	file_scope, file_error := scope_create(&scopes, package_scope, .File)
	if !testing.expect(t, package_error == nil && file_error == nil) { return }
	if !testing.expect(t, bind_builtin_types(&scopes, universe, builtin_types) == nil) { return }
	if !testing.expect(t, bind_universe_builtins(&scopes, universe) == nil && bind_universe_constants(&scopes, universe, &pool)) { return }
	file := File {
		package_id = 1,
		ast        = &ast,
		source     = source,
		scope      = file_scope,
	}
	collection: Collection
	collection_init(&collection, &scopes, context.allocator)
	defer collection_destroy(&collection)
	collection.runtime_scope = package_scope
	if !testing.expect(t, collect_file(&collection, &file, 1, {}) == nil && len(collection.diagnostics) == 0) { return }
	checker: Expression_Checker
	resolver: Resolver
	resolver_init(&resolver, &scopes, expression_declaration, &checker, context.allocator)
	defer resolver_destroy(&resolver)
	type_checker: Type_Checker
	type_checker_init(&type_checker, &resolver, &collection, &store, []^File{nil, &file}, expression_integer_evaluator, &checker, context.allocator)
	defer type_checker_destroy(&type_checker)
	if !testing.expect(
		t,
		expression_checker_init(&checker, &type_checker, &pool, {uintptr = word, layout = types.DEFAULT_LAYOUT}, integer, boolean, context.allocator) == nil,
	) { return }
	defer expression_checker_destroy(&checker)
	for name in ([]string{"type_has_nil", "type_is_any", "type_is_bit_field", "type_is_complex", "type_is_cstring", "type_is_cstring16", "type_is_dereferenceable", "type_is_endian_big", "type_is_endian_little", "type_is_endian_platform", "type_is_fixed_capacity_dynamic_array", "type_is_indexable", "type_is_matrix", "type_is_matrix_column_major", "type_is_matrix_row_major", "type_is_named", "type_is_nearly_simple_compare", "type_is_quaternion", "type_is_rune", "type_is_simd_vector", "type_is_sliceable", "type_is_string", "type_is_string16", "type_is_subtype_of", "type_is_superset_of", "type_is_typeid", "type_is_valid_map_key", "type_is_valid_matrix_elements", "type_is_variant_of", "type_is_integer"}) {
		builtin, failure := expression_builtin_id(&checker, intrinsic_builtin_kind(name))
		id, creation := entity_create(&scopes, Entity{name = name, kind = .Builtin, scope = universe, state = .Resolved, data = builtin})
		_, insertion := scope_insert(&scopes, universe, id)
		if !testing.expect(t, failure == nil && creation == nil && insertion == nil) { return }
	}
	for declaration in collection.declarations {
		state, failure := resolve_entity(&resolver, declaration.entity)
		name := entity_get(&scopes, declaration.entity).name
		invalid := name == "bad_value" || name == "bad_nil" || name == "bad_matrix" || name == "bad_variant" || name == "bad_super" || name == "bad_arity"
		testing.expectf(t, failure == nil && (state == .Invalid) == invalid, "%s: %v %v", name, state, failure)
	}
	for name in ([]string{"row_major_tagged", "col_major_plain", "matrix_yes", "simd_yes", "fixedcap_yes", "bitfield_yes", "complex_yes", "quat_yes", "rune_yes", "string_string", "string_cstring", "string_string16", "string16_yes", "cstring_yes", "cstring16_yes", "any_yes", "typeid_yes", "named_distinct", "named_int", "named_any", "deref_ptr", "deref_named_ptr", "deref_soa", "indexable_array", "indexable_string", "indexable_map", "indexable_multi", "indexable_matrix", "indexable_fixedcap", "sliceable_slice", "sliceable_string", "sliceable_string16", "sliceable_array", "sliceable_dyn", "sliceable_fixedcap", "nearly_float", "nearly_pair", "mapkey_int", "mapkey_string", "mapkey_typeid", "mapkey_pair", "matrixelems_float", "matrixelems_rune", "matrixelems_complex", "endian_platform_int", "endian_little_le", "endian_little_int", "endian_little_ptr", "endian_big_be", "hasnil_ptr", "hasnil_any", "hasnil_union", "hasnil_slice", "hasnil_enum", "hasnil_bitset", "hasnil_map", "hasnil_cstring", "hasnil_typeid", "sub_same", "super_union", "super_enum", "variant_yes"}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, name))
		constant := constant_pool_get(&pool, entity.constant)
		if testing.expectf(t, constant != nil, "%s", name) { testing.expectf(t, constant.value.(bool), "%s", name) }
	}
	for name in ([]string{"row_major_plain", "col_major_tagged", "matrix_no", "simd_no", "fixedcap_no", "bitfield_no", "complex_no", "quat_no", "rune_no", "string16_no", "cstring_no", "cstring16_no", "any_no", "typeid_no", "named_anon", "named_ptr", "deref_rawptr", "deref_multi", "deref_int", "indexable_cstring", "indexable_int", "sliceable_map", "sliceable_multi", "sliceable_matrix", "nearly_string", "mapkey_any", "mapkey_slice", "mapkey_empty", "matrixelems_quat", "matrixelems_bool", "matrixelems_string", "endian_platform_le", "endian_little_struct", "endian_big_int", "endian_platform_struct", "hasnil_int", "hasnil_struct", "hasnil_fixedcap", "hasnil_nonil", "sub_rune_int", "sub_named", "super_union_rev", "super_enum_rev", "variant_no"}) {
		entity := entity_get(&scopes, scope_lookup_current(&scopes, package_scope, name))
		constant := constant_pool_get(&pool, entity.constant)
		if testing.expectf(t, constant != nil, "%s", name) { testing.expectf(t, !constant.value.(bool), "%s", name) }
	}
	invalid_operands := 0
	for diagnostic in checker.diagnostics {
		if diagnostic.kind == .Invalid_Operand { invalid_operands += 1 }
	}
	testing.expectf(t, invalid_operands == 6, "non-type and invalid arguments: %v", checker.diagnostics)
}

@(test)
deferred_type_predicates_stay_unsupported :: proc(t: ^testing.T) {
	specialization := transmute([]byte)string("package sample\nmain :: proc() { _ = type_is_specialization_of(int, int) }\n")
	_, specialization_ok := check_procedure_source(
		t,
		specialization,
		.Unsupported,
		"type_is_specialization_of",
		intrinsic_names = []string{"type_is_specialization_of"},
	)
	testing.expect(t, specialization_ok)
	specialized := transmute([]byte)string("package sample\nmain :: proc() { _ = type_is_specialized_polymorphic_record(int) }\n")
	_, specialized_ok := check_procedure_source(
		t,
		specialized,
		.Unsupported,
		"type_is_specialized_polymorphic_record",
		intrinsic_names = []string{"type_is_specialized_polymorphic_record"},
	)
	testing.expect(t, specialized_ok)
	unspecialized := transmute([]byte)string("package sample\nmain :: proc() { _ = type_is_unspecialized_polymorphic_record(int) }\n")
	_, unspecialized_ok := check_procedure_source(
		t,
		unspecialized,
		.Unsupported,
		"type_is_unspecialized_polymorphic_record",
		intrinsic_names = []string{"type_is_unspecialized_polymorphic_record"},
	)
	testing.expect(t, unspecialized_ok)
}
