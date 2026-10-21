package check

import "core:strings"
import "core:testing"

// By-reference `#soa` iteration binds the scattered element for writing: the
// official compiler accepts the same forms and rejects by-reference over
// call results, map keys and intervals. The accepts fail on the old checker,
// which reported Range_Reference for every `&` value over `#soa`.
@(test)
soa_reference_iteration_checks :: proc(t: ^testing.T) {
	header :: "#+feature using-stmt\npackage sample\nS :: struct { a, b: int }\n"
	accepts := [?]string {
		"c: #soa[4]S\nfor &v in c { v.a = 1 }\nfor &v, i in c { v.b = i }",
		"c: #soa[4]S\nfor &_ in c { }\nfor &_, i in c { _ = i }",
		"d: #soa[dynamic]S\nfor &v in d { v.a = 1 }",
		"s: #soa[]S\nfor &v, i in s { v.b = i }",
		"p: ^#soa[4]S\nfor &v in p { v.a = 1 }\nfor &v in p^ { v.a = 1 }",
		"a: #soa[4][4]u16\nfor &v in a[1] { v = 1 }\nfor &v, j in a[1] { v += u16(j) }",
		"a: #soa[4][4]u16\n#reverse for &v in a[1] { v += 1 }",
		"m: #soa[2][2]u16\nfor &e in m {\nfor &c in e { c = 1 }\n}",
		"c: #soa[4]S\nfor &v in c {\nusing v\na = 1\nb = 2\n}",
		"c: #soa[4]S\nfor v in c {\nusing v\n_ = a + b\n}",
	}
	for body in accepts {
		source := strings.concatenate({header, "main :: proc \"contextless\" () {\n", body, "\n}\n"}, context.temp_allocator)
		procedure, ok := check_procedure_source(t, transmute([]byte)source)
		if !testing.expectf(t, ok, "must check: %s", body) { continue }
		testing.expectf(t, procedure.body_state == .Complete, "must complete: %s", body)
	}
	rejects := [?]struct {
		body, reason: string,
		kind:         Expression_Diagnostic_Kind,
	} {
		{
			"get_soa :: proc \"contextless\" () -> #soa[4]S { s: #soa[4]S\nreturn s }\nmain :: proc \"contextless\" () {\nfor &v in get_soa() { _ = v }\n}",
			"Range_Reference",
			.Unsupported,
		},
		{"main :: proc \"contextless\" () {\nm: map[int]int\nfor &k in m { _ = k }\n}", "Range_Reference", .Unsupported},
		{"main :: proc \"contextless\" () {\nfor &i in 0 ..< 3 { _ = i }\n}", "Range_Form", .Unsupported},
		{"c: #soa[4]S\nmain :: proc \"contextless\" () {\nfor v, &i in c { _, _ = v, i }\n}", "Range_Form", .Unsupported},
		// By-value variables never grant writes: the official compiler
		// reports "Cannot assign" for each of these.
		{"c: #soa[4]S\nmain :: proc \"contextless\" () {\nfor v in c { v = S{} }\n}", "Assign_Destination_Mode", .Unsupported},
		{"c: #soa[4]S\nmain :: proc \"contextless\" () {\nfor v in c { v.b = 1 }\n}", "Assign_Destination_Mode", .Unsupported},
		{"a: #soa[4][4]u16\nmain :: proc \"contextless\" () {\nfor v in a { v[0] = 1 }\n}", "Assign_Destination_Mode", .Unsupported},
	}
	for entry in rejects {
		source := strings.concatenate({header, entry.body, "\n"}, context.temp_allocator)
		_, ok := check_procedure_source(t, transmute([]byte)source, expected_kind = entry.kind, expected_reason = entry.reason)
		testing.expectf(t, ok, "must reject: %s", entry.body)
	}
}
