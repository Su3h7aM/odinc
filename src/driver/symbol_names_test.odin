package driver

import "core:os"
import "core:path/filepath"
import "core:testing"

// Official odin rejects two packages with one name: "Duplicate declaration of 'package util'. A package name must be unique".
@(test)
procedures_in_packages_with_different_names_do_not_collide :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	check_native_section(t, odin_root, directory, "package_procedure_names", 42)
}
