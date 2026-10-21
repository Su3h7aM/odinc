package types

// Ordinary identity ignores tuple and procedure parameter/result names.
are_identical :: proc(store: ^Store, a, b: Type_Id) -> bool {
	return are_identical_internal(store, a, b, false)
}

// Unique-tuple identity also compares names throughout nested signatures.
are_identical_unique_tuples :: proc(store: ^Store, a, b: Type_Id) -> bool {
	return are_identical_internal(store, a, b, true)
}

@(private)
are_identical_internal :: proc(store: ^Store, a, b: Type_Id, check_tuple_names: bool) -> bool {
	if a == b { return true }
	if a == TYPE_NONE || b == TYPE_NONE { return false }
	x, y := get(store, a)^, get(store, b)^
	if x.kind != y.kind { return false }
	// Recursive descriptors close through nominal declarations, never through structural interning.
	if x.is_nominal || y.is_nominal || x.kind == .Named { return false }
	if len(x.fields) != len(y.fields) ||
	   len(x.variants) != len(y.variants) ||
	   len(x.params) != len(y.params) ||
	   len(x.results) != len(y.results) { return false }
	if !are_identical_internal(store, x.elem, y.elem, check_tuple_names) ||
	   !are_identical_internal(store, x.index, y.index, check_tuple_names) ||
	   !are_identical_internal(store, x.backing, y.backing, check_tuple_names) { return false }
	for field, i in x.fields {
		if (x.kind != .Tuple || check_tuple_names) && field.name != y.fields[i].name { return false }
		if field.tag != y.fields[i].tag { return false }
		if !are_identical_internal(store, field.type, y.fields[i].type, check_tuple_names) { return false }
	}
	for variant, i in x.variants {
		if !are_identical_internal(store, variant, y.variants[i], check_tuple_names) { return false }
	}
	for param, i in x.params {
		if !are_identical_internal(store, param, y.params[i], check_tuple_names) { return false }
		if check_tuple_names && signature_name(x.param_names, i) != signature_name(y.param_names, i) { return false }
	}
	for result, i in x.results {
		if !are_identical_internal(store, result, y.results[i], check_tuple_names) { return false }
		if check_tuple_names && signature_name(x.result_names, i) != signature_name(y.result_names, i) { return false }
	}
	x.elem, y.elem, x.index, y.index, x.backing, y.backing = 0, 0, 0, 0, 0, 0
	x.fields, y.fields = nil, nil
	x.variants, y.variants, x.params, y.params, x.results, y.results = nil, nil, nil, nil, nil, nil
	x.param_names, y.param_names, x.result_names, y.result_names = nil, nil, nil, nil
	x.procedure_info, y.procedure_info = 0, 0
	return descriptors_equal(x, y)
}

@(private)
signature_name :: proc(names: []string, index: int) -> string {
	return names[index] if index < len(names) else ""
}
