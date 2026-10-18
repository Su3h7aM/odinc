package driver

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode"

Collection :: struct {
	name: string,
	path: string,
}

Collection_Error :: enum {
	None,
	Invalid_Collection,
	Duplicate_Collection,
	Unknown_Collection,
	Invalid_Import,
	Absolute_Import,
	Missing_Directory,
	Path_Escapes_Root,
}

Collection_Table :: struct {
	allocator:   runtime.Allocator,
	collections: [dynamic]Collection,
	frozen:      bool,
}

collection_table_init :: proc(table: ^Collection_Table, odin_root: string, allocator: runtime.Allocator) -> Collection_Error {
	assert(table != nil && table.allocator.procedure == nil && allocator.procedure != nil)
	table.allocator = allocator
	absolute_root, root_err := filepath.abs(odin_root, allocator)
	if root_err != nil { return .Invalid_Collection }
	defer delete(absolute_root, allocator)
	names := []string{"base", "core", "vendor"}
	for name in names {
		joined, join_err := filepath.join({absolute_root, name}, allocator)
		if join_err != nil { return .Invalid_Collection }
		owned_name, clone_err := strings.clone(name, allocator)
		if clone_err != nil { delete(joined, allocator); return .Invalid_Collection }
		append(&table.collections, Collection{owned_name, joined})
	}
	return .None
}

// Matches main.cpp BuildFlag_Collection and string.cpp string_is_valid_identifier.
collection_add :: proc(table: ^Collection_Table, name, path: string) -> Collection_Error {
	if table == nil ||
	   table.frozen ||
	   !valid_collection_name(name) ||
	   name == "_" ||
	   name == "system" ||
	   path == "" ||
	   strings.index(name, ":") >= 0 ||
	   strings.index(name, "/") >= 0 ||
	   strings.index(name, "\\") >= 0 { return .Invalid_Collection }
	for collection in table.collections {
		if collection.name == name { return .Duplicate_Collection }
	}
	absolute, err := filepath.abs(path, table.allocator)
	if err != nil { return .Missing_Directory }
	info, stat_error := os.stat(absolute, table.allocator)
	if stat_error != nil { delete(absolute, table.allocator); return .Missing_Directory }
	is_directory := info.type == .Directory
	os.file_info_delete(info, table.allocator)
	if !is_directory { delete(absolute, table.allocator); return .Missing_Directory }
	owned_name, clone_err := strings.clone(name, table.allocator)
	if clone_err != nil { delete(absolute, table.allocator); return .Invalid_Collection }
	append(&table.collections, Collection{owned_name, absolute})
	return .None
}

collection_table_freeze :: proc(table: ^Collection_Table) {
	assert(table != nil)
	table.frozen = true
}

collection_table_destroy :: proc(table: ^Collection_Table) {
	if table == nil { return }
	for collection in table.collections {
		delete(collection.name, table.allocator)
		delete(collection.path, table.allocator)
	}
	delete(table.collections)
	table^ = {}
}

resolve_collection_import :: proc(
	table: ^Collection_Table,
	import_path: string,
	importer_directory: string,
	allocator: runtime.Allocator,
) -> (
	path: string,
	err: Collection_Error,
) {
	if table == nil || !table.frozen || import_path == "" { return "", .Invalid_Import }
	if filepath.is_abs(import_path) { return "", .Absolute_Import }

	base := importer_directory
	package_path := import_path
	separator := strings.index(import_path, ":")
	found := separator >= 0
	if found {
		collection_name := import_path[:separator]
		package_path = import_path[separator + 1:]
		if package_path == "" || collection_name == "system" { return "", .Invalid_Import }
		base = ""
		for collection in table.collections {
			if collection.name == collection_name { base = collection.path; break }
		}
		if base == "" { return "", .Unknown_Collection }
	}
	if filepath.is_abs(package_path) { return "", .Absolute_Import }
	joined, join_err := filepath.join({base, package_path}, allocator)
	if join_err != nil { return "", .Invalid_Import }
	defer delete(joined, allocator)
	cleaned, clean_err := filepath.clean(joined, allocator)
	if clean_err != nil { return "", .Invalid_Import }
	absolute, abs_err := filepath.abs(cleaned, allocator)
	delete(cleaned, allocator)
	if abs_err != nil { return "", .Invalid_Import }

	if found && !path_within(base, absolute) {
		delete(absolute, allocator)
		return "", .Path_Escapes_Root
	}
	info, stat_err := os.stat(absolute, allocator)
	if stat_err != nil {
		delete(absolute, allocator)
		return "", .Missing_Directory
	}
	is_directory := info.type == .Directory
	os.file_info_delete(info, allocator)
	if !is_directory {
		delete(absolute, allocator)
		return "", .Missing_Directory
	}
	return absolute, .None
}

@(private = "file")
valid_collection_name :: proc(name: string) -> bool {
	if name == "" { return false }
	for character, index in name {
		if !(character == '_' || unicode.is_letter(character) || index > 0 && unicode.is_digit(character)) {
			return false
		}
	}
	return true
}

@(private = "file")
path_within :: proc(root, path: string) -> bool {
	root_clean, root_err := filepath.clean(root, context.temp_allocator)
	path_clean, path_err := filepath.clean(path, context.temp_allocator)
	if root_err != nil || path_err != nil { return false }
	if root_clean == path_clean { return true }
	prefix, concat_err := strings.concatenate({root_clean, "/"}, context.temp_allocator)
	if concat_err != nil { return false }
	return strings.has_prefix(path_clean, prefix)
}
