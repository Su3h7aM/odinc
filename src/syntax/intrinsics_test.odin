package syntax

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

// base:intrinsics has two stray `)` in the simd_approx_recip declarations. Official Odin accepts them because it
// hardcodes that package; the driver tolerates its parse errors. Only those two lines may fail to parse here.
@(test)
base_intrinsics_parses_real_grammar :: proc(t: ^testing.T) {
	path, _ := filepath.join({#directory, "..", "..", "base", "intrinsics", "intrinsics.odin"}, context.temp_allocator)
	source, read_error := os.read_entire_file_from_path(path, context.allocator)
	defer delete(source)
	if !testing.expect(t, read_error == nil) { return }
	ast: Ast
	ast_init(&ast, context.allocator)
	defer ast_destroy(&ast)
	parser: Parser
	parser_init(&parser, &ast, source, context.allocator)
	defer parser_destroy(&parser)
	parse_file(&parser)
	testing.expect_value(t, len(parser.lex_errors), 0)
	for parse_error in parser.errors {
		line_start := int(parse_error.offset)
		for line_start > 0 && source[line_start - 1] != '\n' { line_start -= 1 }
		testing.expect(t, strings.has_prefix(string(source[line_start:]), "simd_approx_recip"))
	}
	testing.expect_value(t, len(parser.errors), 2)
}
