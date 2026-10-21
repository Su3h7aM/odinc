package check

import "core:testing"
import "oc:types"

@(test)
procedure_info_origin_and_checker_ownership :: proc(t: ^testing.T) {
	store := types.init()
	defer types.destroy(&store)
	type_checker := Type_Checker {
		store = &store,
	}
	pool: Constant_Pool
	first, second: Expression_Checker
	if !testing.expect(t, expression_checker_init(&first, &type_checker, &pool, {}, 0, 0, context.allocator) == nil) { return }
	defer expression_checker_destroy(&first)
	if !testing.expect(t, expression_checker_init(&second, &type_checker, &pool, {}, 0, 0, context.allocator) == nil) { return }
	defer expression_checker_destroy(&second)
	origin := Procedure_Info_Origin {
		signature = {1, 2},
		scope     = 3,
		view      = 4,
	}
	defaults := []Default_Argument{{value = Operand(Const_Id(7))}}
	flags := []Entity_Flags{{.Any_Integer}}
	id, err := expression_procedure_info_intern(&first, origin, {defaults, flags})
	if !testing.expect(t, err == nil && id != 0) { return }
	defaults[0] = {}
	flags[0] = {}
	again, again_error := expression_procedure_info_intern(&first, origin, {})
	testing.expect(t, again_error == nil && again == id)
	info, lookup_error := expression_procedure_info(&first, id)
	if !testing.expect(t, lookup_error == .None && info != nil) { return }
	testing.expect(t, info.defaults[0].value == Operand(Const_Id(7)) && .Any_Integer in info.parameter_flags[0])
	for changed in ([]Procedure_Info_Origin{{signature = {1, 2}, scope = 5, view = 4}, {signature = {1, 2}, scope = 3, view = 6}, {signature = {1, 8}, scope = 3, view = 4}}) {
		other, other_error := expression_procedure_info_intern(&first, changed, {})
		testing.expect(t, other_error == nil && other != id)
	}
	second_id, second_error := expression_procedure_info_intern(&second, origin, {})
	testing.expect(t, second_error == nil && second_id != id)
	missing, missing_error := expression_procedure_info(&second, id)
	testing.expect(t, missing == nil && missing_error == .Invalid_Id)
	unowned, unowned_error := expression_procedure_info(&first, second_id)
	testing.expect(t, unowned == nil && unowned_error == .Invalid_Id)
	absent, absent_error := expression_procedure_info(&first, 0)
	testing.expect(t, absent == nil && absent_error == .None)
}
