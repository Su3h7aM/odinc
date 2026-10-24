package check

import "base:runtime"
import "core:mem"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "oc:syntax"

Collection_Diagnostic_Kind :: enum u8 {
	None,
	Redeclaration,
	Named_Result_Shadow,
	Invalid_Private,
	Repeated_Private,
	Private_Test,
	Using_At_File,
	Using_Constant,
	Invalid_Foreign_Entity,
	Invalid_Foreign_Library,
	Missing_Initializer,
	Invalid_Name,
	Arity,
	Unknown_Attribute,
	Link_Name_Conflict,
}

// Placeholder for F3. Names and source bytes are borrowed; related identifies the earlier binding.
Collection_Diagnostic :: struct {
	kind:            Collection_Diagnostic_Kind,
	name:            string,
	source, related: Source_Span,
}

Collection_Visibility :: enum u8 {
	Public,
	Package,
	File,
}

Pending_Declaration_Kind :: enum u8 {
	None,
	Import,
	Foreign_Import,
	Foreign_Block,
	When,
	Directive,
}
Pending_Declaration :: struct {
	entity:                     Entity_Id,
	kind:                       Pending_Declaration_Kind,
	declaration, foreign_block: Node_Ref,
	visibility:                 Collection_Visibility,
	order:                      Source_Order,
	handled:                    bool,
}
Collected_Declaration :: struct {
	entity:                                 Entity_Id,
	identifier, type, value, foreign_block: Node_Ref,
}

// Owns collection records only. The scope store, files, ASTs and source bytes must outlive it.
Collection :: struct {
	scopes:          ^Scope_Store,
	allocator:       mem.Allocator,
	// Entities of `@(builtin)` declarations in runtime_package are also bound here, the universal scope.
	builtin_scope:   Scope_Id,
	runtime_package: Package_Id,
	runtime_scope:   Scope_Id,
	declarations:    [dynamic]Collected_Declaration,
	pending:         [dynamic]Pending_Declaration,
	diagnostics:     [dynamic]Collection_Diagnostic,
	file_features:   [dynamic][]string,
	// Decoded link names stored in entities; borrowed attribute text is never added.
	owned_names:     [dynamic]string,
}

collection_init :: proc(collection: ^Collection, scopes: ^Scope_Store, allocator: mem.Allocator) {
	assert(collection != nil && collection.scopes == nil && scopes != nil && scopes.allocator.procedure != nil)
	assert(allocator.procedure != nil)
	collection.scopes = scopes
	collection.allocator = allocator
	collection.declarations.allocator = allocator
	collection.pending.allocator = allocator
	collection.diagnostics.allocator = allocator
	collection.file_features.allocator = allocator
	collection.owned_names.allocator = allocator
}

collection_destroy :: proc(collection: ^Collection) {
	if collection == nil { return }
	if collection.scopes != nil {
		for entity in collection.scopes.entities {
			library, is_library := entity.data.(Library_Data)
			if !is_library { continue }
			for path in library.paths {
				delete(path.name, collection.allocator)
			}
			delete(library.paths, collection.allocator)
			delete(library.expressions, collection.allocator)
		}
	}
	delete(collection.declarations)
	delete(collection.pending)
	delete(collection.diagnostics)
	for features in collection.file_features { delete(features, collection.allocator) }
	delete(collection.file_features)
	for name in collection.owned_names { delete(name, collection.allocator) }
	delete(collection.owned_names)
	collection^ = {}
}

// Call once per parsed file, in stable file order. Allocation failure aborts collection, not a retry.
@(require_results)
collect_file :: proc(collection: ^Collection, file: ^File, id: File_Id, order: Source_Order) -> Binding_Error {
	assert(collection.scopes != nil && id != 0 && file.ast != nil)
	scope := scope_get(collection.scopes, file.scope)
	assert(scope != nil && scope.kind == .File)
	assert(scope_get(collection.scopes, scope.parent).kind == .Package)
	root := syntax.node_payload(file.ast, file.ast.root, syntax.File)
	collect_file_features(collection, file, root) or_return
	return collect_declarations(collection, file, id, syntax.node_list(file.ast, root.decls), order, 0, .Public)
}

// The expression checker supplies the condition only after ordinary declarations are available.
@(require_results)
collect_when_arm :: proc(collection: ^Collection, file: ^File, pending_index: int, condition: bool) -> Binding_Error {
	pending := collection.pending[pending_index]
	assert(pending.kind == .When && !pending.handled)
	statement := syntax.node_payload(file.ast, pending.declaration.node, syntax.When_Stmt)
	selected := statement.else_stmt
	if condition { selected = statement.body }
	if selected != 0 {
		if file.ast.nodes[selected].kind == .When_Stmt {
			append(
				&collection.pending,
				Pending_Declaration {
					kind = .When,
					declaration = {pending.declaration.file, selected},
					foreign_block = pending.foreign_block,
					visibility = pending.visibility,
					order = pending.order,
				},
			) or_return
		} else {
			body := syntax.node_payload(file.ast, selected, syntax.Block_Stmt)
			first_entity := len(collection.scopes.entities)
			defer for &entity in collection.scopes.entities[first_entity:] { entity.flags += {.In_When} }
			collect_declarations(
				collection,
				file,
				pending.declaration.file,
				syntax.node_list(file.ast, body.stmts),
				pending.order,
				pending.foreign_block.node,
				pending.visibility,
			) or_return
		}
	}
	collection.pending[pending_index].handled = true
	return nil
}

// C3 supplies the evaluated foreign-block visibility; other attributes remain in its AST.
@(require_results)
collect_foreign_block :: proc(collection: ^Collection, file: ^File, pending_index: int, visibility: Collection_Visibility) -> Binding_Error {
	pending := collection.pending[pending_index]
	assert(pending.kind == .Foreign_Block && !pending.handled)
	declaration := syntax.node_payload(file.ast, pending.declaration.node, syntax.Foreign_Block_Decl)
	body := syntax.node_payload(file.ast, declaration.body, syntax.Block_Stmt)
	collect_declarations(
		collection,
		file,
		pending.declaration.file,
		syntax.node_list(file.ast, body.stmts),
		pending.order,
		pending.declaration.node,
		visibility,
	) or_return
	collection.pending[pending_index].handled = true
	return nil
}

// `system:name` names a system library; any other path is relative to the importing file unless absolute.
@(private = "file")
collect_library_data :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	fullpaths: syntax.Node_Range,
) -> (
	data: Library_Data,
	err: runtime.Allocator_Error,
) {
	paths := make([dynamic]Library_Path, collection.allocator) or_return
	expressions := make([dynamic]syntax.Node_Index, collection.allocator) or_return
	for node in syntax.node_list(file.ast, fullpaths) {
		literal := file.ast.nodes[node].kind == .Basic_Lit
		if literal {
			kind := syntax.node_payload(file.ast, node, syntax.Basic_Lit).kind
			literal = kind == .String || kind == .Raw_String
		}
		// Any other path is a constant expression, evaluated once the checker exists (check_library_paths).
		if !literal {
			append(&expressions, node) or_return
			continue
		}
		text, allocated, valid := strconv.unquote_string(collection_node_text(file, node), collection.allocator)
		library: Library_Path
		if valid { library, valid = library_path_from_text(file, text, collection.allocator) or_return }
		if allocated { delete(text, collection.allocator) }
		if !valid {
			collection_report(collection, file, id, node, .Invalid_Foreign_Library) or_return
			continue
		}
		append(&paths, library) or_return
	}
	if len(expressions) == 0 { delete(expressions) }
	return Library_Data{paths = paths[:], expressions = expressions[:]}, nil
}

// `system:name` names a system library; any other path is relative to the importing file unless absolute. The name is
// allocated with `allocator`.
@(private = "package")
library_path_from_text :: proc(file: ^File, text: string, allocator: runtime.Allocator) -> (library: Library_Path, valid: bool, err: runtime.Allocator_Error) {
	library.name = text
	if colon := strings.index_byte(text, ':'); colon >= 0 {
		library = Library_Path {
			system = text[:colon] == "system",
			name   = text[colon + 1:],
		}
		if !library.system { return {}, false, nil }
	}
	if len(library.name) == 0 { return {}, false, nil }
	if library.system || filepath.is_abs(library.name) {
		library.name = strings.clone(library.name, allocator) or_return
	} else {
		library.name = filepath.join({filepath.dir(file.path), library.name}, allocator) or_return
	}
	return library, true, nil
}

// C3 supplies the resolved package name, or the decoded library name, after loading/evaluation.
// Supplied name bytes must outlive the scope store. Eager library bindings are not recreated.
@(require_results)
collect_import_name :: proc(collection: ^Collection, file: ^File, pending_index: int, name: string, package_id: Package_Id = 0) -> Binding_Error {
	pending := collection.pending[pending_index]
	assert(!pending.handled && (pending.kind == .Import || pending.kind == .Foreign_Import))
	if pending.entity != 0 {
		collection.pending[pending_index].handled = true
		return nil
	}
	declaration := pending.declaration.node
	identifier: syntax.Node_Index
	kind: Entity_Kind
	data: Entity_Data
	flags: Entity_Flags
	destination := file.scope
	if pending.kind == .Import {
		import_decl := syntax.node_payload(file.ast, declaration, syntax.Import_Decl)
		identifier = import_decl.name
		kind = .Import_Name
		data = Import_Data {
			package_id = package_id,
		}
		if import_decl.is_using { flags += {.Using} }
		if collection_has_attribute(file.ast, file.source, import_decl.attributes, "require") { flags += {.Required} }
		path, allocated, valid := strconv.unquote_string(collection_node_text(file, import_decl.relpath), context.temp_allocator)
		if valid && (path == "base:builtin" || path == "base:intrinsics") { flags += {.Used} }
		if allocated { delete(path, context.temp_allocator) }
	} else {
		import_decl := syntax.node_payload(file.ast, declaration, syntax.Foreign_Import_Decl)
		identifier = import_decl.name
		kind = .Library_Name
		library := collect_library_data(collection, file, pending.declaration.file, import_decl.fullpaths) or_return
		data = library
		if collection_has_attribute(file.ast, file.source, import_decl.attributes, "export") {
			destination = scope_get(collection.scopes, file.scope).parent
			flags += {.Export}
		}
	}
	binding_name := name
	if identifier != 0 { binding_name = collection_node_text(file, identifier) }
	anchor := identifier
	if anchor == 0 { anchor = declaration }
	entity := collect_entity(
		collection,
		file,
		pending.declaration.file,
		declaration,
		anchor,
		binding_name,
		kind,
		flags,
		data,
		pending.order,
		destination,
		0,
		0,
		0,
	) or_return
	collection.pending[pending_index].entity = entity
	collection.pending[pending_index].handled = true
	return nil
}

@(private = "file")
collect_declarations :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	nodes: []syntax.Node_Index,
	order: Source_Order,
	foreign_block: syntax.Node_Index,
	visibility: Collection_Visibility,
) -> Binding_Error {
	for node in nodes {
		#partial switch file.ast.nodes[node].kind {
		case .Expr_Stmt:
			append(&collection.pending, Pending_Declaration{kind = .Directive, declaration = {id, node}, order = order}) or_return
		case .Value_Decl:
			collect_value_declaration(collection, file, id, node, order, foreign_block, visibility) or_return
		case .Import_Decl:
			append(&collection.pending, Pending_Declaration{kind = .Import, declaration = {id, node}, order = order}) or_return
		case .Foreign_Import_Decl:
			decl := syntax.node_payload(file.ast, node, syntax.Foreign_Import_Decl)
			if decl.name == 0 {
				append(&collection.pending, Pending_Declaration{kind = .Foreign_Import, declaration = {id, node}, order = order}) or_return
			} else {
				flags: Entity_Flags
				destination := file.scope
				library := collect_library_data(collection, file, id, decl.fullpaths) or_return
				if collection_has_attribute(file.ast, file.source, decl.attributes, "export") {
					destination = scope_get(collection.scopes, file.scope).parent
					flags += {.Export}
				}
				entity := collect_entity(
					collection,
					file,
					id,
					node,
					decl.name,
					collection_node_text(file, decl.name),
					.Library_Name,
					flags,
					library,
					order,
					destination,
					0,
					0,
					0,
				) or_return
				append(&collection.pending, Pending_Declaration{kind = .Foreign_Import, entity = entity, declaration = {id, node}, order = order}) or_return
			}
		case .Foreign_Block_Decl:
			decl := syntax.node_payload(file.ast, node, syntax.Foreign_Block_Decl)
			body := syntax.node_payload(file.ast, decl.body, syntax.Block_Stmt)
			eager := true
			for child in syntax.node_list(file.ast, body.stmts) {
				if file.ast.nodes[child].kind != .Value_Decl { eager = false; break }
			}
			for attribute in syntax.node_list(file.ast, decl.attributes) {
				for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
					if file.ast.nodes[element].kind == .Field_Value {
						value := syntax.node_payload(file.ast, element, syntax.Field_Value).value
						if value != 0 && file.ast.nodes[value].kind != .Basic_Lit { eager = false }
					}
				}
			}
			if !eager {
				append(
					&collection.pending,
					Pending_Declaration{kind = .Foreign_Block, declaration = {id, node}, order = order, visibility = visibility},
				) or_return
				continue
			}
			block_visibility, _, _ := collect_attributes(collection, file, id, decl.attributes, visibility, false) or_return
			collect_declarations(collection, file, id, syntax.node_list(file.ast, body.stmts), order, node, block_visibility) or_return
		case .When_Stmt:
			append(
				&collection.pending,
				Pending_Declaration{kind = .When, declaration = {id, node}, foreign_block = {id, foreign_block}, visibility = visibility, order = order},
			) or_return
		}
	}
	return nil
}

@(private = "file")
collect_value_declaration :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	node: syntax.Node_Index,
	order: Source_Order,
	foreign_block: syntax.Node_Index,
	inherited_visibility: Collection_Visibility,
) -> Binding_Error {
	decl := syntax.node_payload(file.ast, node, syntax.Value_Decl)
	block_attributes: syntax.Node_Range
	if foreign_block != 0 { block_attributes = syntax.node_payload(file.ast, foreign_block, syntax.Foreign_Block_Decl).attributes }
	values := syntax.node_list(file.ast, decl.values)
	is_procedure := len(values) > 0
	for value in values {
		target := value
		for target != 0 && file.ast.nodes[target].kind == .Paren_Expr {
			target = syntax.node_payload(file.ast, target, syntax.Paren_Expr).expr
		}
		if target == 0 || file.ast.nodes[target].kind != .Proc_Lit {
			is_procedure = false
			break
		}
	}
	visibility, flags, private_test, attribute_err := collect_attributes(collection, file, id, decl.attributes, inherited_visibility, is_procedure)
	if attribute_err != nil { return attribute_err }
	if private_test {
		collection_report(collection, file, id, node, .Private_Test) or_return
		return nil
	}
	if visibility == .Public { visibility = collection_file_visibility(file) }
	if visibility == .Package { flags += {.Private_Package} }
	if visibility == .File { flags += {.Private_File} }
	if foreign_block != 0 { flags += {.Foreign} }
	if decl.is_using && decl.is_mutable {
		names := syntax.node_list(file.ast, decl.names)
		if len(names) > 0 { collection_report(collection, file, id, names[0], .Using_At_File) or_return }
	}
	for name, index in syntax.node_list(file.ast, decl.names) {
		if file.ast.nodes[name].kind != .Ident {
			collection_report(collection, file, id, name, .Invalid_Name) or_return
			continue
		}
		value: syntax.Node_Index
		if index < len(values) { value = values[index] }
		for value != 0 && file.ast.nodes[value].kind == .Paren_Expr {
			value = syntax.node_payload(file.ast, value, syntax.Paren_Expr).expr
		}
		kind := Entity_Kind.Constant
		data: Entity_Data
		type := decl.type
		if decl.is_mutable {
			kind = .Variable
			storage := Storage_Kind.Thread_Local if collection_has_attribute(file.ast, file.source, decl.attributes, "thread_local") else .Global
			data = Variable_Data {
				storage     = storage,
				initializer = {id, value},
			}
		} else if value == 0 {
			collection_report(collection, file, id, name, .Missing_Initializer) or_return
			continue
		} else {
			value_kind := file.ast.nodes[value].kind
			if (.Typeid_Type <= value_kind && value_kind <= .Bit_Field_Type) || is_type_of_call(file, value) {
				kind = .Type_Name
				type = value
			} else if value_kind == .Proc_Lit {
				kind = .Procedure
				literal := syntax.node_payload(file.ast, value, syntax.Proc_Lit)
				type = literal.type
				data = Procedure_Data {
					source_name   = collection_node_text(file, name),
					body          = {id, literal.body},
					where_clauses = literal.where_clauses,
				}
			} else if value_kind == .Proc_Group {
				kind = .Procedure_Group
				data = Procedure_Group_Data{}
			} else if value_kind == .Asm_Template {
				kind = .Assembly_Template
			}
			if decl.is_using && !(kind == .Type_Name && value_kind == .Enum_Type) {
				collection_report(collection, file, id, name, .Using_Constant) or_return
			}
			if foreign_block != 0 && kind != .Procedure {
				collection_report(collection, file, id, name, .Invalid_Foreign_Entity) or_return
			}
		}
		entity_flags := flags
		if decl.is_using && !decl.is_mutable && kind == .Type_Name { entity_flags += {.Using} }
		destination := file.scope
		if visibility != .File { destination = scope_get(collection.scopes, file.scope).parent }
		entity_order := order
		entity_order.declaration_index = u32(index)
		entity := collect_entity(
			collection,
			file,
			id,
			node,
			name,
			collection_node_text(file, name),
			kind,
			entity_flags,
			data,
			entity_order,
			destination,
			type,
			value,
			foreign_block,
		) or_return
		if foreign_block != 0 {
			library_ident := syntax.node_payload(file.ast, foreign_block, syntax.Foreign_Block_Decl).foreign_library
			entity_get(collection.scopes, entity).foreign_library = collection_node_text(file, library_ident)
		}
		link_name := collection_link_name(collection, file, id, name, decl.attributes, block_attributes) or_return
		entity_get(collection.scopes, entity).link_name = link_name
		if collection.builtin_scope != 0 &&
		   file.package_id == collection.runtime_package &&
		   collection_has_attribute(file.ast, file.source, decl.attributes, "builtin") {
			_, insert_error := scope_insert(collection.scopes, collection.builtin_scope, entity)
			if insert_error != nil { return insert_error }
		}
	}
	if len(values) > 0 && len(values) != int(decl.names.count) {
		collection_report(collection, file, id, values[len(values) - 1], .Arity) or_return
	}
	return nil
}

@(private = "file")
collect_entity :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	declaration, identifier: syntax.Node_Index,
	name: string,
	kind: Entity_Kind,
	flags: Entity_Flags,
	data: Entity_Data,
	order: Source_Order,
	destination: Scope_Id,
	type, value, foreign_block: syntax.Node_Index,
) -> (
	created: Entity_Id,
	err: Binding_Error,
) {
	entity_order := order
	entity_order.offset = file.ast.nodes[identifier].start
	entity_flags := flags
	if file.ast.lazy { entity_flags += {.Lazy} }
	entity, create_err := entity_create(
		collection.scopes,
		Entity {
			name = name,
			kind = kind,
			flags = entity_flags,
			scope = file.scope,
			package_id = file.package_id,
			declaration = {id, declaration},
			order = entity_order,
			data = data,
		},
	)
	if create_err != nil { return 0, create_err }
	append(
		&collection.declarations,
		Collected_Declaration{entity = entity, identifier = {id, identifier}, type = {id, type}, value = {id, value}, foreign_block = {id, foreign_block}},
	) or_return
	previous := scope_insert(collection.scopes, destination, entity) or_return
	if previous != 0 {
		old := entity_get(collection.scopes, previous)
		diagnostic := Collection_Diagnostic {
			kind    = .Redeclaration,
			name    = name,
			source  = {id, entity_order.offset, file.ast.nodes[identifier].end},
			related = {old.declaration.file, old.order.offset, old.order.offset + u32(len(old.name))},
		}
		if .Result in old.flags { diagnostic.kind = .Named_Result_Shadow }
		if collection_order_before(entity_order, old.order) {
			diagnostic.source, diagnostic.related = diagnostic.related, diagnostic.source
		}
		append(&collection.diagnostics, diagnostic) or_return
	}
	return entity, nil
}

@(private = "file")
collect_attributes :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	attributes: syntax.Node_Range,
	inherited: Collection_Visibility,
	is_procedure: bool,
) -> (
	visibility: Collection_Visibility,
	flags: Entity_Flags,
	private_test: bool,
	err: runtime.Allocator_Error,
) {
	visibility = inherited
	has_private, has_test := false, false
	for attribute in syntax.node_list(file.ast, attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			name := element
			value: syntax.Node_Index
			if file.ast.nodes[element].kind == .Field_Value {
				field := syntax.node_payload(file.ast, element, syntax.Field_Value)
				name, value = field.field, field.value
			}
			switch collection_node_text(file, name) {
			case "private":
				requested := Collection_Visibility.Package
				valid := value == 0
				if value != 0 && file.ast.nodes[value].kind == .Basic_Lit {
					kind := syntax.node_payload(file.ast, value, syntax.Basic_Lit).kind
					if kind == .String || kind == .Raw_String {
						text, allocated, ok := strconv.unquote_string(collection_node_text(file, value), collection.allocator)
						valid = ok && (text == "file" || text == "package")
						if text == "file" { requested = .File }
						if allocated { delete(text, collection.allocator) }
					}
				}
				if !valid {
					collection_report(collection, file, id, value, .Invalid_Private) or_return
				} else {
					has_private = true
				}
				if visibility >= requested {
					collection_report(collection, file, id, element, .Repeated_Private) or_return
				} else {
					visibility = requested
				}
			case "test":
				has_test = true
				flags += {.Test}
			case "export":
				flags += {.Export}
			case "require":
				if value == 0 { flags += {.Required} }
			case "rodata":
				flags += {.Rodata}
			case "deferred",
			     "deferred_none",
			     "deferred_in",
			     "deferred_out",
			     "deferred_in_out",
			     "deferred_in_by_ptr",
			     "deferred_out_by_ptr",
			     "deferred_in_out_by_ptr":
				// Procedure targets resolve after collection, so the expression
				// checker validates these. Anywhere else they are unknown.
				if !is_procedure {
					collection_report(collection, file, id, element, .Unknown_Attribute) or_return
				}
			case:
				if !is_procedure && !declaration_attribute_known(collection_node_text(file, name)) {
					collection_report(collection, file, id, element, .Unknown_Attribute) or_return
				}
			}
		}
	}
	private_test = has_private && has_test
	return
}

@(private = "package")
collection_report :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	node: syntax.Node_Index,
	kind: Collection_Diagnostic_Kind,
) -> runtime.Allocator_Error {
	span := file.ast.nodes[node]
	_, err := append(&collection.diagnostics, Collection_Diagnostic{kind = kind, source = {id, span.start, span.end}})
	return err
}

// Text of a `name = "text"` attribute: found is false when absent, and text is "" for a bare or non-string value.
// Allocated is true only when text owns heap bytes that the caller must free or transfer.
@(private = "file")
collection_attribute_text :: proc(
	collection: ^Collection,
	file: ^File,
	attributes: syntax.Node_Range,
	name: string,
) -> (
	text: string,
	allocated: bool,
	found: bool,
	err: runtime.Allocator_Error,
) {
	for attribute in syntax.node_list(file.ast, attributes) {
		for element in syntax.node_list(file.ast, syntax.node_payload(file.ast, attribute, syntax.Attribute).elems) {
			identifier := element
			value: syntax.Node_Index
			if file.ast.nodes[element].kind == .Field_Value {
				field := syntax.node_payload(file.ast, element, syntax.Field_Value)
				identifier, value = field.field, field.value
			}
			if collection_node_text(file, identifier) != name { continue }
			if value == 0 || file.ast.nodes[value].kind != .Basic_Lit { return "", false, true, nil }
			kind := syntax.node_payload(file.ast, value, syntax.Basic_Lit).kind
			if kind != .String && kind != .Raw_String { return "", false, true, nil }
			unquoted, was_allocated, ok := strconv.unquote_string(collection_node_text(file, value), collection.allocator)
			if !ok { return "", false, true, nil }
			return unquoted, was_allocated, true, nil
		}
	}
	return "", false, false, nil
}

// The declaration's attribute, else the foreign block's: the block supplies the default for its procedures.
@(private = "file")
collection_link_part :: proc(
	collection: ^Collection,
	file: ^File,
	attributes, block_attributes: syntax.Node_Range,
	name: string,
) -> (
	text: string,
	allocated: bool,
	err: runtime.Allocator_Error,
) {
	found: bool
	text, allocated, found, err = collection_attribute_text(collection, file, attributes, name)
	if err != nil || found { return }
	text, allocated, _, err = collection_attribute_text(collection, file, block_attributes, name)
	return
}

// The symbol name from the link attributes, as the official handle_link_name: `link_name` replaces the name, and
// `link_prefix` and `link_suffix` wrap the bare name. "" keeps the default name.
@(private = "package")
collection_link_name :: proc(
	collection: ^Collection,
	file: ^File,
	id: File_Id,
	name: syntax.Node_Index,
	attributes, block_attributes: syntax.Node_Range,
) -> (
	link_name: string,
	err: Binding_Error,
) {
	explicit, explicit_allocated, _ := collection_attribute_text(collection, file, attributes, "link_name") or_return
	if explicit != "" {
		// An inherited block prefix or suffix is dropped by a link_name; only the declaration's own conflicts.
		own_prefix, own_prefix_allocated, _ := collection_attribute_text(collection, file, attributes, "link_prefix") or_return
		own_suffix, own_suffix_allocated, _ := collection_attribute_text(collection, file, attributes, "link_suffix") or_return
		defer if own_prefix_allocated { delete(own_prefix, collection.allocator) }
		defer if own_suffix_allocated { delete(own_suffix, collection.allocator) }
		if own_prefix != "" || own_suffix != "" { collection_report(collection, file, id, name, .Link_Name_Conflict) or_return }
		if explicit_allocated { append(&collection.owned_names, explicit) or_return }
		return explicit, nil
	}
	prefix, prefix_allocated := collection_link_part(collection, file, attributes, block_attributes, "link_prefix") or_return
	suffix, suffix_allocated := collection_link_part(collection, file, attributes, block_attributes, "link_suffix") or_return
	if prefix == "" && suffix == "" { return "", nil }
	joined := strings.concatenate({prefix, collection_node_text(file, name), suffix}, collection.allocator) or_return
	if prefix_allocated { delete(prefix, collection.allocator) }
	if suffix_allocated { delete(suffix, collection.allocator) }
	append(&collection.owned_names, joined) or_return
	return joined, nil
}

@(private = "file")
collection_node_text :: proc(file: ^File, node: syntax.Node_Index) -> string {
	span := file.ast.nodes[node]
	return string(file.source[span.start:span.end])
}

@(private = "package")
collection_has_attribute :: proc(ast: ^syntax.Ast, source: []byte, attributes: syntax.Node_Range, name: string) -> bool {
	for attribute in syntax.node_list(ast, attributes) {
		for element in syntax.node_list(ast, syntax.node_payload(ast, attribute, syntax.Attribute).elems) {
			identifier := element
			if ast.nodes[element].kind == .Field_Value { identifier = syntax.node_payload(ast, element, syntax.Field_Value).field }
			span := ast.nodes[identifier]
			if string(source[span.start:span.end]) == name { return true }
		}
	}
	return false
}

@(private = "file")
collection_file_visibility :: proc(file: ^File) -> Collection_Visibility {
	root := syntax.node_payload(file.ast, file.ast.root, syntax.File)
	for tag in syntax.node_list(file.ast, root.tags) {
		source := file.ast.nodes[tag]
		tokenizer := syntax.init(file.source[source.start + 2:source.end], nil, nil)
		token := syntax.next(&tokenizer)
		if syntax.token_text(tokenizer.source, token) == "private" {
			argument := syntax.next(&tokenizer)
			if syntax.token_text(tokenizer.source, argument) == "file" { return .File }
			return .Package
		}
	}
	return .Public
}

@(private = "file")
collection_order_before :: proc(left, right: Source_Order) -> bool {
	if left.package_order != right.package_order { return left.package_order < right.package_order }
	if left.file_order != right.file_order { return left.file_order < right.file_order }
	if left.offset != right.offset { return left.offset < right.offset }
	return left.declaration_index < right.declaration_index
}
