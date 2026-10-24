package check

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:strings"
import "oc:syntax"
import "oc:types"

// Comma-separated feature names to a set. A leading `+` or `-` only affects
// the enabled check; validity is decided by the bare name, as upstream does.
@(private = "package")
parse_target_feature_names :: proc(names: string) -> (set: types.X86_Features, invalid: string, ok: bool) {
	set, _, invalid, ok = parse_target_feature_names_arch(names, false)
	return
}

// The same parse against every architecture's names. Only declarations use
// it: a foreign name there stays valid and disables or stamps as upstream does.
@(private = "package")
parse_target_feature_names_globally :: proc(names: string) -> (set: types.X86_Features, invalid: string, ok: bool) {
	set, _, invalid, ok = parse_target_feature_names_arch(names, true)
	return
}

@(private = "file")
parse_target_feature_names_arch :: proc(names: string, global: bool) -> (set, disabled: types.X86_Features, invalid: string, ok: bool) {
	remaining := names
	for name in strings.split_iterator(&remaining, ",") {
		token := target_feature_bare_name(name)
		if global {
			if !target_feature_valid_globally(name) { return {}, {}, name, false }
		} else if !types.target_feature_known(token, x86_only = true) {
			return {}, {}, name, false
		}
		feature, modeled := types.parse_x86_feature(token)
		if !modeled { continue }
		if strings.has_prefix(name, "-") {
			removed := types.x86_disabled_features({feature})
			set -= removed
			disabled |= removed
		} else {
			added := types.x86_enabled_features({feature})
			set |= added
			disabled -= added
		}
	}
	return set, disabled, "", true
}

// The name without a leading `+` or `-` sign.
@(private = "file")
target_feature_bare_name :: proc(name: string) -> string {
	if strings.has_prefix(name, "+") || strings.has_prefix(name, "-") { return name[1:] }
	return name
}

// Whether the name is valid on any architecture. The target check below stays
// x86-only: a foreign name in a procedure attribute is diagnosed at the call.
@(private = "package")
target_feature_valid_globally :: proc(name: string) -> bool {
	token := target_feature_bare_name(name)
	return types.target_feature_known(token)
}

// Raw require and enable lists for a procedure entity: the signature's
// stamped info where present, else the declaration attributes. The fallback
// covers generic procedures, whose info is only stamped at instantiation.
@(private = "package")
entity_target_features :: proc(checker: ^Expression_Checker, id: Entity_Id) -> (require, enable: string, err: Resolve_Error) {
	entity := entity_get(checker.type_checker.resolver.scopes, id)
	if entity.kind != .Procedure { return "", "", nil }
	if procedure, is_procedure := entity.data.(Procedure_Data); is_procedure && procedure.signature != 0 {
		store := checker.type_checker.store
		descriptor := types.get(store, types.resolve_named(store, procedure.signature))
		if descriptor.kind == .Procedure {
			if info, info_error := expression_procedure_info(checker, descriptor.procedure_info); info_error == .None && info != nil {
				if info.require_target_feature != "" || info.enable_target_feature != "" {
					return info.require_target_feature, info.enable_target_feature, nil
				}
			}
		}
	}
	require = procedure_attribute_text(checker, entity^, "require_target_feature") or_return
	enable = procedure_attribute_text(checker, entity_get(checker.type_checker.resolver.scopes, id)^, "enable_target_feature") or_return
	return require, enable, nil
}

// Text of a target feature attribute on the entity's declaration: a string
// literal, or any other constant expression in the declaration's scope, as
// upstream evaluates attribute values. A non-constant value counts as absent,
// like a bare attribute.
@(private = "file")
procedure_attribute_text :: proc(checker: ^Expression_Checker, entity: Entity, name: string) -> (text: string, err: Resolve_Error) {
	if entity.declaration.node == 0 { return "", nil }
	file := checker.type_checker.files[entity.declaration.file]
	if file.ast.nodes[entity.declaration.node].kind != .Value_Decl { return "", nil }
	decl := syntax.node_payload(file.ast, entity.declaration.node, syntax.Value_Decl)
	for attribute in syntax.node_list(file.ast, decl.attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			identifier := element
			value: syntax.Node_Index
			if file.ast.nodes[element].kind == .Field_Value {
				field := syntax.node_payload(file.ast, element, syntax.Field_Value)
				identifier, value = field.field, field.value
			}
			span := file.ast.nodes[identifier]
			if string(file.source[span.start:span.end]) != name || value == 0 { continue }
			if file.ast.nodes[value].kind == .Basic_Lit {
				kind := syntax.node_payload(file.ast, value, syntax.Basic_Lit).kind
				if kind != .String && kind != .Raw_String { return "", nil }
				literal := file.ast.nodes[value]
				unquoted, _, ok := strconv.unquote_string(string(file.source[literal.start:literal.end]), mem.dynamic_arena_allocator(&checker.arena))
				if !ok { return "", nil }
				return unquoted, nil
			}
			view := expression_file_view(checker, entity.declaration.file) or_return
			valued := check_expression(checker, view, entity.scope, value) or_return
			if valued.state == .Invalid { return "", nil }
			if constant, is_string := constant_pool_get(checker.constants, valued.constant).value.(string); valued.mode == .Constant && is_string {
				return constant, nil
			}
			return "", nil
		}
	}
	return "", nil
}


// Every name in the required list holds against the global set: bare and
// `+` names must be present, `-` names must be absent. Unknown names never hold.
@(private = "package")
target_features_satisfied :: proc(global: types.X86_Features, required: string) -> (missing: string, ok: bool) {
	remaining := required
	for name in strings.split_iterator(&remaining, ",") {
		token, want := name, true
		if strings.has_prefix(token, "+") {
			token = token[1:]
		} else if strings.has_prefix(token, "-") {
			token, want = token[1:], false
		}
		feature, modeled := types.parse_x86_feature(token)
		enabled := modeled && feature in global
		if !types.target_feature_known(token) || enabled != want { return name, false }
	}
	return "", true
}

// Every comma-separated token of the wanted list is present verbatim in the held list.
@(private = "package")
target_feature_superset :: proc(held, wanted: string) -> (missing: string, ok: bool) {
	remaining := wanted
	for name in strings.split_iterator(&remaining, ",") {
		found := false
		held_names := held
		for candidate in strings.split_iterator(&held_names, ",") {
			if candidate == name { found = true; break }
		}
		if !found { return name, false }
	}
	return "", true
}

// Reads `@(require_target_feature)` / `@(enable_target_feature)` off the
// procedure declaration, reports conflicting or invalid lists, and disables an
// entity whose required features the global level does not satisfy. The raw
// lists are returned for the signature's procedure info. Like upstream, an
// invalid list is reported but still stamped, so the call site reports it again.
@(private = "package")
check_procedure_target_features :: proc(checker: ^Expression_Checker, scope: Scope_Id, id: Entity_Id) -> (require, enable: string, err: Resolve_Error) {
	scopes := checker.type_checker.resolver.scopes
	require_text := procedure_attribute_text(checker, entity_get(scopes, id)^, "require_target_feature") or_return
	enable_text := procedure_attribute_text(checker, entity_get(scopes, id)^, "enable_target_feature") or_return
	entity := entity_get(scopes, id)
	view := expression_file_view(checker, entity.declaration.file) or_return
	if require_text != "" && enable_text != "" {
		expression_failure(
			checker,
			view,
			scope,
			entity.declaration.node,
			.Target_Feature,
			`A procedure cannot have both @(require_target_feature="...") and @(enable_target_feature="...")`,
		) or_return
	}
	if require_text != "" {
		if _, invalid, features_valid := parse_target_feature_names_globally(require_text); !features_valid {
			expression_failure(
				checker,
				view,
				scope,
				entity.declaration.node,
				.Target_Feature,
				fmt.tprintf("Required target feature '%s' is not a valid target feature", invalid),
			) or_return
		} else if _, satisfied := target_features_satisfied(types.x86_level_features(checker.microarch), require_text); !satisfied {
			entity.flags += {.Disabled}
		}
	} else if enable_text != "" {
		if _, invalid, features_valid := parse_target_feature_names_globally(enable_text); !features_valid {
			expression_failure(
				checker,
				view,
				scope,
				entity.declaration.node,
				.Target_Feature,
				fmt.tprintf("Procedure enabled target feature '%s' is not a valid target feature", invalid),
			) or_return
		}
	}
	return require_text, enable_text, nil
}

// Enforces the callee's target features at a call: the required list must
// hold globally (a caller's own enable list never satisfies it), and an
// inlined call into an enabled procedure needs the same features enabled by
// the enclosing procedure. callee is 0 for calls through a procedure value.
@(private = "package")
check_call_target_features :: proc(
	checker: ^Expression_Checker,
	view: View_Id,
	scope: Scope_Id,
	node: syntax.Node_Index,
	proc_type: types.Type_Id,
	callee: Entity_Id,
) -> (
	allowed: bool,
	err: Resolve_Error,
) {
	store := checker.type_checker.store
	descriptor := types.get(store, types.resolve_named(store, proc_type))
	if descriptor.kind != .Procedure { return true, nil }
	require, enable := "", ""
	if callee != 0 {
		require, enable = entity_target_features(checker, callee) or_return
	} else if info, info_error := expression_procedure_info(checker, descriptor.procedure_info); info_error == .None && info != nil {
		require, enable = info.require_target_feature, info.enable_target_feature
	}
	if require == "" && enable == "" { return true, nil }
	if require != "" {
		if _, invalid, features_valid := parse_target_feature_names(require); !features_valid {
			expression_failure(
				checker,
				view,
				scope,
				node,
				.Target_Feature,
				fmt.tprintf("Called procedure requires target feature '%s' which is invalid for the build target", invalid),
			) or_return
			return false, nil
		}
		if missing, satisfied := target_features_satisfied(types.x86_level_features(checker.microarch), require); !satisfied {
			expression_failure(
				checker,
				view,
				scope,
				node,
				.Target_Feature,
				fmt.tprintf("Calling this procedure requires target feature '%s' to be enabled", missing),
			) or_return
			return false, nil
		}
	}
	if enable == "" || !call_target_features_inlined(checker, view, node, callee) { return true, nil }
	caller, caller_found := enclosing_procedure_target_features(checker, scope) or_return
	if !caller_found {
		expression_failure(
			checker,
			view,
			scope,
			node,
			.Target_Feature,
			"Calling a '#force_inline' procedure that enables target features is not allowed at file scope",
		) or_return
		return false, nil
	}
	if missing, superset := target_feature_superset(caller, enable); !superset {
		expression_failure(
			checker,
			view,
			scope,
			node,
			.Target_Feature,
			fmt.tprintf(
				"Inlined procedure enables target feature '%s', this requires the calling procedure to at least enable the same feature\nSuggested Example: @(enable_target_feature=\"%s\")",
				missing,
				missing,
			),
		) or_return
		return false, nil
	}
	return true, nil
}

// The call is inlined when the call itself is marked `#force_inline` or the
// callee procedure is. Values carry no inlining tag, so indirect calls only
// inline through the call-site marker.
@(private = "file")
call_target_features_inlined :: proc(checker: ^Expression_Checker, view: View_Id, node: syntax.Node_Index, callee: Entity_Id) -> bool {
	file := checker.type_checker.files[checker.views[view].file]
	if syntax.node_payload(file.ast, node, syntax.Call_Expr).inlining == .Inline { return true }
	if callee == 0 { return false }
	scopes := checker.type_checker.resolver.scopes
	entity := entity_get(scopes, callee)
	if entity.kind != .Procedure || entity.declaration.node == 0 { return false }
	declaration_file := checker.type_checker.files[entity.declaration.file]
	if declaration_file.ast.nodes[entity.declaration.node].kind != .Value_Decl { return false }
	declaration := syntax.node_payload(declaration_file.ast, entity.declaration.node, syntax.Value_Decl)
	for value in syntax.node_list(declaration_file.ast, declaration.values) {
		if declaration_file.ast.nodes[value].kind != .Proc_Lit { continue }
		return syntax.node_payload(declaration_file.ast, value, syntax.Proc_Lit).inlining == .Inline
	}
	return false
}

// The raw enable list of the procedure enclosing the scope, or found=false at file scope.
@(private = "file")
enclosing_procedure_target_features :: proc(checker: ^Expression_Checker, scope: Scope_Id) -> (enable: string, found: bool, err: Resolve_Error) {
	scopes := checker.type_checker.resolver.scopes
	current := scope
	for current != 0 {
		resolved := scope_get(scopes, current)
		if resolved.kind == .Procedure {
			owner := entity_get(scopes, resolved.owner)
			if owner.kind != .Procedure { return "", true, nil }
			_, owner_enable := entity_target_features(checker, resolved.owner) or_return
			return owner_enable, true, nil
		}
		current = resolved.parent
	}
	return "", false, nil
}

// The effective code generation set of a checked procedure: its parsed
// enable list under the global level it was checked against.
@(private = "package")
procedure_effective_features :: proc(
	checker: ^Expression_Checker,
	id: Entity_Id,
) -> (
	features: types.X86_Features,
	disabled: types.X86_Features,
	level: types.X86_Level,
	err: Resolve_Error,
) {
	level = checker.microarch
	_, enable := entity_target_features(checker, id) or_return
	if enable == "" { return {}, {}, level, nil }
	set, disabled_set, _, features_valid := parse_target_feature_names_arch(enable, true)
	if !features_valid { return {}, {}, level, nil }
	return set, disabled_set, level, nil
}
