package driver

import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
type_info_value_passed_to_typeid_is_rejected_with_official_text :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "type_info_argument", "main.odin"}, context.temp_allocator)
	builder: strings.Builder
	strings.builder_init(&builder, context.temp_allocator)
	image, err := build_file(odin_root, main_path, strings.to_writer(&builder), context.allocator)
	testing.expect_value(t, err, Build_Error(Driver_Error.Check_Failed))
	testing.expect_value(t, len(image), 0)
	testing.expect(
		t,
		strings.contains(
			strings.to_string(builder),
			"main.odin:6:11: Conversion Cannot assign value 'type_info_of(int)' of type '^Type_Info' to 'typeid' in a procedure argument\n",
		),
		strings.to_string(builder),
	)
}
