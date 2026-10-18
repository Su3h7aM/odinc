package driver

import "base:runtime"
import "core:strings"

// Maps a written import path to its package directory, as parser.cpp determine_path_from_string does for
// Linux: core:runtime, core:intrinsics and core:builtin name base packages. A path without a collection is
// relative to the importer's directory.
import_directory :: proc(table: ^Collection_Table, import_path, importer_directory: string, allocator: runtime.Allocator) -> (string, Collection_Error) {
	resolved_path := import_path
	if strings.has_prefix(import_path, "core:") {
		package_path := import_path[len("core:"):]
		head, _, _ := strings.partition(package_path, "/")
		if head == "runtime" || head == "intrinsics" || head == "builtin" {
			base_path, concat_error := strings.concatenate({"base:", package_path}, context.temp_allocator)
			if concat_error != nil { return "", .Invalid_Import }
			resolved_path = base_path
		}
	}
	return resolve_collection_import(table, resolved_path, importer_directory, allocator)
}
