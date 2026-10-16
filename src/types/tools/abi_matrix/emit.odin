package main

import "core:fmt"
import "core:strings"
import types "oc:types"

c_scalar :: proc(kind: Scalar) -> string {
	switch kind {
	case .U8:
		return "unsigned char"
	case .I8:
		return "signed char"
	case .U16:
		return "unsigned short"
	case .I16:
		return "short"
	case .U32:
		return "unsigned int"
	case .I32:
		return "int"
	case .U64:
		return "unsigned long"
	case .I64:
		return "long"
	case .U128:
		return "unsigned __int128"
	case .I128:
		return "__int128"
	case .F16:
		return "_Float16"
	case .F32:
		return "float"
	case .F64:
		return "double"
	case .Ptr:
		return "void *"
	case .Bool:
		return "_Bool"
	}
	return ""
}

odin_scalar :: proc(kind: Scalar) -> string {
	switch kind {
	case .U8:
		return "u8"
	case .I8:
		return "i8"
	case .U16:
		return "u16"
	case .I16:
		return "i16"
	case .U32:
		return "u32"
	case .I32:
		return "i32"
	case .U64:
		return "u64"
	case .I64:
		return "i64"
	case .U128:
		return "u128"
	case .I128:
		return "i128"
	case .F16:
		return "f16"
	case .F32:
		return "f32"
	case .F64:
		return "f64"
	case .Ptr:
		return "rawptr"
	case .Bool:
		return "bool"
	}
	return ""
}

c_name :: proc(index: int) -> string {
	spec := specs[index]
	switch spec.kind {
	case .Scalar:
		return c_scalar(spec.scalar)
	case .Struct, .Union:
		return fmt.tprintf("S%d", index)
	case .Vector:
		return fmt.tprintf("V%d", index)
	case .Array:
		return fmt.tprintf("A%d", index)
	}
	return ""
}

odin_name :: proc(index: int) -> string {
	spec := specs[index]
	switch spec.kind {
	case .Scalar:
		return odin_scalar(spec.scalar)
	case .Struct, .Union:
		return fmt.tprintf("S%d", index)
	case .Vector:
		return fmt.tprintf("#simd[%d]%s", spec.count, odin_name(spec.members[0]))
	case .Array:
		return fmt.tprintf("[%d]%s", spec.count, odin_name(spec.members[0]))
	}
	return ""
}

function_name :: proc(index: int) -> string {
	return fmt.tprintf("f%03d", index)
}

c_declaration :: proc(builder: ^strings.Builder, name: string, index: int) {
	spec := specs[index]
	if spec.kind == .Array {
		fmt.sbprintf(builder, "%s %s[%d]", c_name(spec.members[0]), name, spec.count)
	} else {
		fmt.sbprintf(builder, "%s %s", c_name(index), name)
	}
}

c_prototype :: proc(index: int) -> string {
	signature := signatures[index]
	builder := strings.builder_make()
	result := "void" if signature.result == VOID else c_name(signature.result)
	fmt.sbprintf(&builder, "%s %s(", result, function_name(index))
	for param, i in signature.params {
		if i > 0 { strings.write_string(&builder, ", ") }
		fmt.sbprintf(&builder, "%s a%d", c_name(param), i)
	}
	strings.write_string(&builder, ")")
	return strings.to_string(builder)
}

emit_c :: proc() -> string {
	builder := strings.builder_make()
	for spec, index in specs {
		switch spec.kind {
		case .Scalar, .Array:
		case .Struct, .Union:
			keyword := "struct" if spec.kind == .Struct else "union"
			fmt.sbprintf(&builder, "typedef %s {{ ", keyword)
			for member, i in spec.members {
				c_declaration(&builder, fmt.tprintf("m%d", i), member)
				strings.write_string(&builder, "; ")
			}
			fmt.sbprintf(&builder, "}} %s;\n", c_name(index))
		case .Vector:
			element := specs[spec.members[0]].scalar
			fmt.sbprintf(&builder, "typedef %s %s __attribute__((vector_size(%d)));\n", c_scalar(element), c_name(index), spec.count * scalar_bytes(element))
		}
	}
	for signature, index in signatures {
		if signature.result == VOID {
			fmt.sbprintf(&builder, "%s {{}}\n", c_prototype(index))
		} else {
			fmt.sbprintf(&builder, "%s {{ %s result = {{0}}; return result; }}\n", c_prototype(index), c_name(signature.result))
		}
	}
	return strings.to_string(builder)
}

emit_odin :: proc() -> string {
	builder := strings.builder_make()
	strings.write_string(&builder, "package main\n\n")
	for spec, index in specs {
		switch spec.kind {
		case .Scalar, .Array, .Vector:
		case .Struct, .Union:
			fmt.sbprintf(&builder, "S%d :: struct ", index)
			if spec.kind == .Union { strings.write_string(&builder, "#raw_union ") }
			strings.write_string(&builder, "{ ")
			for member, i in spec.members { fmt.sbprintf(&builder, "m%d: %s, ", i, odin_name(member)) }
			strings.write_string(&builder, "}\n")
		}
	}
	for signature, index in signatures {
		fmt.sbprintf(&builder, "@(export)\n%s :: proc \"c\" (", function_name(index))
		for param, i in signature.params {
			if i > 0 { strings.write_string(&builder, ", ") }
			fmt.sbprintf(&builder, "a%d: %s", i, odin_name(param))
		}
		strings.write_string(&builder, ")")
		if signature.result != VOID { fmt.sbprintf(&builder, " -> (result: %s)", odin_name(signature.result)) }
		strings.write_string(&builder, " { return }\n")
	}
	strings.write_string(&builder, "\nmain :: proc() {}\n")
	return strings.to_string(builder)
}

// build_store creates the types.Store entry of every spec, in spec order.
build_store :: proc(store: ^types.Store) -> []types.Type_Id {
	ids := make([]types.Type_Id, len(specs))
	for spec, index in specs {
		switch spec.kind {
		case .Scalar:
			ids[index] = scalar_type(store, spec.scalar)
		case .Struct, .Union:
			fields := make([]types.Type_Field, len(spec.members))
			for member, i in spec.members { fields[i] = types.Type_Field{"", ids[member]} }
			ids[index] = types.intern(store, types.Type{kind = .Struct, fields = fields, raw_union = spec.kind == .Union})
		case .Array:
			ids[index] = types.intern(store, types.Type{kind = .Array, elem = ids[spec.members[0]], count = i64(spec.count)})
		case .Vector:
			ids[index] = types.intern(store, types.Type{kind = .Simd_Vector, elem = ids[spec.members[0]], count = i64(spec.count)})
		}
	}
	return ids
}

scalar_type :: proc(store: ^types.Store, kind: Scalar) -> types.Type_Id {
	bytes := i64(scalar_bytes(kind))
	switch kind {
	case .U8, .U16, .U32, .U64, .U128:
		return types.intern(store, types.Type{kind = .Integer, count = bytes})
	case .I8, .I16, .I32, .I64, .I128:
		return types.intern(store, types.Type{kind = .Integer, count = bytes, signed = true})
	case .F16, .F32, .F64:
		return types.intern(store, types.Type{kind = .Float, count = bytes})
	case .Ptr:
		return types.intern(store, types.Type{kind = .Raw_Pointer})
	case .Bool:
		return types.intern(store, types.Type{kind = .Bool, count = 1})
	}
	return types.TYPE_NONE
}

// canonical_plan renders a plan in the comparison form shared with the LLVM
// signatures: integer pieces "I<bytes>", SSE pieces "S<bytes>", "BV@<align>",
// "SRET", with z/s for extended scalars; result extension is reported apart and
// the xmm0:xmm1 pieces of a wide vector result are joined to one vector.
canonical_plan :: proc(plan: types.Abi_Plan) -> (text: string, result_extension: bool) {
	params := make([dynamic]string)
	results := make([dynamic]string)
	for param in plan.params {
		switch param.attr {
		case .Direct:
			token := piece_token(param.type, param.size, param.ext)
			if param.align == 16 && param.type != .V128 { token = fmt.tprintf("%s@16", token) }
			append(&params, token)
		case .By_Value:
			append(&params, fmt.tprintf("BV@%d", param.align))
		case .Struct_Return:
			append(&params, "SRET")
		case .Indirect:
			append(&params, "IND")
		case .Context:
			append(&params, "CTX")
		}
	}
	for result in plan.results {
		if result.type == .V128 && len(results) > 0 && results[len(results) - 1] == "S16" {
			results[len(results) - 1] = fmt.tprintf("S%d", 16 + result.size)
			continue
		}
		append(&results, piece_token(result.type, result.size, .None))
		result_extension ||= result.ext != .None
	}
	return fmt.tprintf("%s -> %s", strings.join(params[:], " "), strings.join(results[:], " ")), result_extension
}

piece_token :: proc(piece: types.Abi_Piece, size: u32, ext: types.Abi_Extension) -> string {
	suffix := ""
	if ext == .Zero { suffix = "z" }
	if ext == .Sign { suffix = "s" }
	switch piece {
	case .I8, .I16, .I32, .I64, .Ptr:
		return fmt.tprintf("I%d%s", size, suffix)
	case .F16, .F32, .F64, .V128:
		return fmt.tprintf("S%d", size)
	}
	return "?"
}

plan_for :: proc(store: ^types.Store, ids: []types.Type_Id, index: int) -> (text: string, result_extension: bool, err: types.Plan_Error) {
	signature := signatures[index]
	params := make([]types.Type_Id, len(signature.params))
	for param, i in signature.params { params[i] = ids[param] }
	results: []types.Type_Id
	if signature.result != VOID {
		results = make([]types.Type_Id, 1)
		results[0] = ids[signature.result]
	}
	procedure := types.intern(store, types.Type{kind = .Procedure, convention = .C, params = params, results = results})
	plan := types.plan_abi(store, procedure) or_return
	text, result_extension = canonical_plan(plan)
	return
}
