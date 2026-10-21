package types

import "core:testing"

@(test)
procedure_metadata_identity :: proc(t: ^testing.T) {
	store := init()
	defer destroy(&store)
	first_id := issue_procedure_info_id(&store)
	second_id := issue_procedure_info_id(&store)
	testing.expect(t, first_id != 0 && second_id != first_id)
	first := intern(&store, Type{kind = .Procedure, procedure_info = first_id})
	second := intern(&store, Type{kind = .Procedure, procedure_info = second_id})
	absent := intern(&store, Type{kind = .Procedure})
	testing.expect_value(t, intern(&store, get(&store, first)^), first)
	for other in ([]Type_Id{second, absent}) {
		testing.expect(t, first != other)
		first_array := intern(&store, Type{kind = .Array, elem = first, count = 2})
		other_array := intern(&store, Type{kind = .Array, elem = other, count = 2})
		testing.expect(t, first_array != other_array)
		testing.expect(t, are_identical(&store, first_array, other_array))
		testing.expect(t, are_identical_unique_tuples(&store, first_array, other_array))
	}
}

@(test)
signature_identity_and_owned_names :: proc(t: ^testing.T) {
	store := init()
	defer destroy(&store)
	integer := sized_integer(&store, 8, true)
	params := []Type_Id{integer}
	results := []Type_Id{integer}
	name_bytes := []u8{'v', 'a', 'l', 'u', 'e'}
	names := []string{string(name_bytes)}
	x := intern(&store, Type{kind = .Procedure, params = params, results = results, param_names = names, result_names = []string{"out"}})
	testing.expect_value(t, intern(&store, get(&store, x)^), x)
	name_bytes[0] = 'X'
	names[0] = "changed"
	testing.expect_value(t, get(&store, x).param_names[0], "value")
	y := intern(&store, Type{kind = .Procedure, params = params, results = results, param_names = []string{"other"}, result_names = []string{"out"}})
	z := intern(&store, Type{kind = .Procedure, params = params, results = results, param_names = []string{"value"}, result_names = []string{"result"}})
	unnamed := intern(&store, Type{kind = .Procedure, params = params, results = results})
	empty := intern(&store, Type{kind = .Procedure, params = params, results = results, param_names = []string{""}, result_names = []string{""}})
	blank := intern(&store, Type{kind = .Procedure, params = params, results = results, param_names = []string{"_"}})
	testing.expect(t, x != y && x != z && unnamed != empty)
	for other in ([]Type_Id{y, z, unnamed, empty, blank}) {
		testing.expect(t, are_identical(&store, x, other))
		testing.expect(t, !are_identical_unique_tuples(&store, x, other))
	}
	testing.expect(t, are_identical_unique_tuples(&store, unnamed, empty))
	testing.expect(t, !are_identical_unique_tuples(&store, unnamed, blank))
	x_pointer := intern(&store, Type{kind = .Pointer, elem = x})
	y_pointer := intern(&store, Type{kind = .Pointer, elem = y})
	x_outer := intern(&store, Type{kind = .Procedure, params = []Type_Id{x_pointer}})
	y_outer := intern(&store, Type{kind = .Procedure, params = []Type_Id{y_pointer}})
	testing.expect(t, are_identical(&store, x_outer, y_outer))
	testing.expect(t, !are_identical_unique_tuples(&store, x_outer, y_outer))
	different := intern(&store, Type{kind = .Procedure, params = params, results = results, variadic = true})
	testing.expect(t, !are_identical(&store, x, different))
	structure := intern(&store, Type{kind = .Struct, fields = []Type_Field{{name = "first", type = x}}})
	renamed := intern(&store, Type{kind = .Struct, fields = []Type_Field{{name = "second", type = y}}})
	same_fields := intern(&store, Type{kind = .Struct, fields = []Type_Field{{name = "first", type = y}}})
	testing.expect(t, !are_identical(&store, structure, renamed))
	testing.expect(t, are_identical(&store, structure, same_fields))
	testing.expect(t, !are_identical_unique_tuples(&store, structure, same_fields))
	first_tuple := intern(&store, Type{kind = .Tuple, fields = []Type_Field{{name = "first", type = x}}})
	second_tuple := intern(&store, Type{kind = .Tuple, fields = []Type_Field{{name = "second", type = y}}})
	testing.expect(t, are_identical(&store, first_tuple, second_tuple))
	testing.expect(t, !are_identical_unique_tuples(&store, first_tuple, second_tuple))
}

@(test)
nominal_identity_terminates_recursive_signatures :: proc(t: ^testing.T) {
	store := init()
	defer destroy(&store)
	left := reserve_nominal(&store, .Named, "Node")
	right := reserve_nominal(&store, .Named, "Node")
	left_pointer := intern(&store, Type{kind = .Pointer, elem = left})
	right_pointer := intern(&store, Type{kind = .Pointer, elem = right})
	left_fields := []Type_Field{{name = "next", type = left_pointer}}
	right_fields := []Type_Field{{name = "next", type = right_pointer}}
	left_struct := intern(&store, Type{kind = .Struct, fields = left_fields})
	right_struct := intern(&store, Type{kind = .Struct, fields = right_fields})
	complete_nominal(&store, left, Type{kind = .Named, name = "Node", elem = left_struct})
	complete_nominal(&store, right, Type{kind = .Named, name = "Node", elem = right_struct})
	first := intern(&store, Type{kind = .Procedure, params = []Type_Id{left_pointer}, param_names = []string{"a"}})
	second := intern(&store, Type{kind = .Procedure, params = []Type_Id{left_pointer}, param_names = []string{"b"}})
	other := intern(&store, Type{kind = .Procedure, params = []Type_Id{right_pointer}})
	testing.expect(t, are_identical(&store, first, second))
	testing.expect(t, !are_identical_unique_tuples(&store, first, second))
	testing.expect(t, !are_identical(&store, first, other))
	testing.expect(t, !are_identical_unique_tuples(&store, first, other))
	testing.expect(t, !are_identical(&store, left, left_struct))
	for kind in ([]Kind{.Struct, .Union, .Enum}) {
		a := reserve_nominal(&store, kind, "Separate")
		b := reserve_nominal(&store, kind, "Separate")
		testing.expect(t, are_identical(&store, a, a))
		testing.expect(t, !are_identical(&store, a, b))
	}
}
