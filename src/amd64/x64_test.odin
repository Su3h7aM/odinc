package amd64

import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "oc:ir"
import "oc:regalloc"

@(test)
assignment_matches_system_v_rules :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	integer :: ir.Param {
		type = .I64,
	}
	wide_low :: ir.Param {
		type  = .I64,
		align = 16,
	}
	Case :: struct {
		name:    string,
		params:  []ir.Param,
		results: []ir.Result,
		want:    string,
	}
	cases := []Case {
		{"seven integers", {integer, integer, integer, integer, integer, integer, integer}, nil, "r7 r6 r2 r1 r8 r9 s0 | 8"},
		{"sixth integer fills r9", {integer, integer, integer, integer, integer, wide_low, integer}, nil, "r7 r6 r2 r1 r8 r9 s0 | 8"},
		{"i128 on the stack", {integer, integer, integer, integer, integer, integer, wide_low, integer}, nil, "r7 r6 r2 r1 r8 r9 s0 s8 | 16"},
		{
			"nine doubles",
			{{type = .F64}, {type = .F64}, {type = .F64}, {type = .F64}, {type = .F64}, {type = .F64}, {type = .F64}, {type = .F64}, {type = .F64}},
			nil,
			"x0 x1 x2 x3 x4 x5 x6 x7 s0 | 8",
		},
		{
			"by value after a stack word",
			{integer, integer, integer, integer, integer, integer, integer, {attr = .By_Value, size = 12, align = 16}},
			nil,
			"r7 r6 r2 r1 r8 r9 s0 s16 | 32",
		},
		{"mixed results", nil, {{type = .I64}, {type = .F64}}, "| 0 -> r0 x0"},
		{"two integer results", nil, {{type = .I64}, {type = .I64}}, "| 0 -> r0 r2"},
		{"three integer results", nil, {{type = .I64}, {type = .I64}, {type = .I64}}, "error"},
	}
	for c in cases {
		assignment, err := assign_signature(ir.Signature{cc = .C, params = c.params, results = c.results}, allocator)
		got := "error"
		if err == nil {
			builder: strings.Builder
			strings.builder_init(&builder, allocator)
			for location in assignment.params {
				if location.kind == .Register {
					strings.write_string(&builder, "r" if location.class == .Int else "x")
					strings.write_int(&builder, int(location.register))
				} else {
					strings.write_string(&builder, "s")
					strings.write_int(&builder, int(location.offset))
				}
				strings.write_byte(&builder, ' ')
			}
			strings.write_string(&builder, "| ")
			strings.write_int(&builder, int(assignment.stack_bytes))
			if len(assignment.results) > 0 {
				strings.write_string(&builder, " ->")
				for location in assignment.results {
					strings.write_string(&builder, " r" if location.class == .Int else " x")
					strings.write_int(&builder, int(location.register))
				}
			}
			got = strings.to_string(builder)
		}
		testing.expect_value(t, got, c.want)
	}
}

@(test)
call_sequence_builds_a_verified_program :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect_value(t, virtual.arena_init_growing(&arena), nil)
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)

	caller := ir.Signature {
		cc      = .C,
		params  = []ir.Param{{type = .Ptr}, {type = .I8, ext = .Zero}},
		results = []ir.Result{{type = .I64}},
	}
	callee := ir.Signature {
		cc       = .C,
		variadic = true,
		params   = []ir.Param{{type = .I64}, {type = .F64}},
		results  = []ir.Result{{type = .I8, ext = .Sign}},
	}
	caller_assignment, callee_assignment: Assignment
	err: Abi_Error
	caller_assignment, err = assign_signature(caller, allocator)
	testing.expect_value(t, err, nil)
	callee_assignment, err = assign_signature(callee, allocator)
	testing.expect_value(t, err, nil)

	function: Machine_Function
	testing.expect_value(t, machine_function_init(&function, "caller"), nil)
	defer machine_function_destroy(&function)
	block, _ := add_block(&function)
	params, start_err := lower_start(&function, block, caller, caller_assignment, allocator)
	testing.expect_value(t, start_err, nil)
	scalar, _ := new_vreg(&function, .Float)
	results, call_err := lower_call(
		&function,
		block,
		callee,
		callee_assignment,
		Symbol_Target{symbol = {.Function, 1}},
		[]Vreg{params[0].(Vreg), scalar},
		allocator,
	)
	testing.expect_value(t, call_err, nil)
	testing.expect_value(t, lower_return(&function, block, caller, caller_assignment, params, results, allocator), nil)

	testing.expect_value(t, verify_machine(&function), Verify_Error{})
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	print_function(&function, &builder)
	want := `machine caller outgoing=0
b0:
  Entry v0@7, v1@6
  Copy v3, v0
  Copy v4, v2
  MOV.4 v5, #1
  Call sym1.1+0, v3@7, v4@0, v5@0, v6@0
  Copy v7, v6
  Return v7@0
`
	testing.expect_value(t, strings.to_string(builder), want)

	program, program_err := build_program(&function, allocator)
	testing.expect_value(t, program_err, nil)
	instructions := program.blocks[0].instructions
	call := instructions[4]
	testing.expect(t, call.is_call)
	testing.expect_value(t, call.operands[0].constraint, regalloc.Constraint.Fixed)
	testing.expect_value(t, call.operands[0].fixed, regalloc.Register(Gpr.RDI))
	testing.expect_value(t, call.operands[3].role, regalloc.Operand_Role.Def)
	testing.expect(t, instructions[1].is_move)
}
