package driver

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
rtti_union_tag_identity_and_formatting :: proc(t: ^testing.T) {
	odin_root, _ := filepath.join({#directory, "..", ".."}, context.temp_allocator)
	main_path, _ := filepath.join({#directory, "testdata", "rtti_union", "main.odin"}, context.temp_allocator)
	build_log: strings.Builder
	defer strings.builder_destroy(&build_log)
	image, err := build_file(odin_root, main_path, strings.to_writer(&build_log), context.allocator, 1)
	if !testing.expectf(t, err == nil, "%v\n%s", err, strings.to_string(build_log)) { return }
	defer delete(image)
	directory := native_section_test_directory(t)
	defer os.remove_all(directory)
	path, _ := filepath.join({directory, "rtti_union"}, context.temp_allocator)
	if !testing.expect(t, write_executable(path, image) == nil) { return }
	devnull, open_err := os.open("/dev/null", {.Write})
	if !testing.expect(t, open_err == nil) { return }
	defer _ = os.close(devnull)
	output_path, _ := filepath.join({directory, "stdout"}, context.temp_allocator)
	state, output, output_open_err, process_err, wait_err, output_err := run_raw_data_child(path, output_path, devnull)
	if !testing.expect(t, output_open_err == nil && process_err == nil && wait_err == nil && output_err == nil) { return }
	testing.expect_value(t, state.exit_code, 0)
	testing.expect_value(
		t,
		string(output),
		"42\ntrue 8\n42 Value\nRecord{value = 7} Record\nSecond Choice\nFlags{low = 3, high = 5} Flags\nBox($T=int){value = 9} Box($T=int)\n11 Number\nValue main true\nRecord main true\nChoice main true\nFlags main true\nBox($T=int) main true\nNumber main true\nLocal_Record{value = 13} Local_Record\n15 Local_Value\nSecond Local_Choice\nLocal_Flags{value = 17} Local_Flags\n19 Local_Number\nLocal_Record main true\nLocal_Value main true\nLocal_Choice main true\nLocal_Flags main true\nLocal_Number main true\n",
	)
}
