package driver

import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
unsupported_import_is_located_and_fails_the_build :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "unsupported_import", "main.odin"}, context.temp_allocator)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	image, err := build_file(odin_root, main_path, strings.to_writer(&builder), context.allocator, 1)
	testing.expect_value(t, err, Build_Error(Driver_Error.Unsupported_Import))
	testing.expect_value(t, len(image), 0)
	testing.expect(
		t,
		strings.contains(strings.to_string(builder), "main.odin:3:8: unsupported import \"core:no_such_package\"\n"),
		"diagnostic must locate the import path",
	)
}
