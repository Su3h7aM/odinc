package check

// Evaluates the library paths of `foreign import` declarations that are constant expressions rather than string
// literals, like `foreign import lib { LIB }` or `"a" when X else "b"`, as the official check_foreign_import does.
// Run once the declarations of the package are collected and its `when` statements are bound.
check_library_paths :: proc(checker: ^Expression_Checker) -> Resolve_Error {
	scopes := checker.type_checker.resolver.scopes
	collection := checker.type_checker.collection
	for index := 1; index < len(scopes.entities); index += 1 {
		id := Entity_Id(index)
		library, is_library := entity_get(scopes, id).data.(Library_Data)
		if !is_library || len(library.expressions) == 0 { continue }
		file_id := entity_get(scopes, id).declaration.file
		file := checker.type_checker.files[file_id]
		view := expression_file_view(checker, file_id) or_return
		paths := make([dynamic]Library_Path, collection.allocator) or_return
		append(&paths, ..library.paths) or_return
		for node in library.expressions {
			info := check_expression(checker, view, file.scope, node) or_return
			if info.state == .Invalid { continue }
			text, is_string := constant_pool_get(checker.constants, info.constant).value.(string)
			path: Library_Path
			valid: bool
			if info.mode == .Constant && is_string {
				path, valid = library_path_from_text(file, text, collection.allocator) or_return
			}
			if !valid {
				collection_report(collection, file, file_id, node, .Invalid_Foreign_Library) or_return
				continue
			}
			append(&paths, path) or_return
		}
		data := &entity_get(scopes, id).data.(Library_Data)
		delete(library.expressions, collection.allocator)
		delete(library.paths, collection.allocator)
		data.paths = paths[:]
		data.expressions = nil
	}
	return nil
}
