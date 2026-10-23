package analysis

import "base:runtime"
import "core:mem"
import "oc:check"
import "oc:syntax"

Options :: struct {
	no_entry_point, test: bool,
}

Diagnostic :: struct {
	severity: check.Diagnostic_Severity,
	source:   check.Source_Span,
	reason:   string,
}

// Sources and semantic tables are borrowed; diagnostics and their text belong to the result's arena.
Result :: struct {
	diagnostics: []Diagnostic,
	enabled:     syntax.Analysis_Flags,
	procedures:  []Procedure,
	events:      []Event,
	arena:       ^mem.Dynamic_Arena,
	allocator:   runtime.Allocator,
}

run :: proc(program: ^check.Checked_Program, options: Options, allocator := context.allocator) -> (result: Result, err: runtime.Allocator_Error) {
	for file in program.files {
		if file.ast != nil { result.enabled += file.ast.analysis }
	}
	result.allocator = allocator
	result.arena = new(mem.Dynamic_Arena, allocator) or_return
	mem.dynamic_arena_init(result.arena, block_allocator = allocator, array_allocator = allocator)
	defer if err != nil { destroy(&result) }
	arena_allocator := mem.dynamic_arena_allocator(result.arena)
	run := Run {
		program     = program,
		allocator   = arena_allocator,
		procedures  = make([dynamic]Procedure, 0, arena_allocator) or_return,
		events      = make([dynamic]Event, 0, arena_allocator) or_return,
		diagnostics = make([dynamic]Diagnostic, 0, arena_allocator) or_return,
	}
	inventory(&run) or_return
	check_unsafe_returns(&run) or_return
	result.procedures = run.procedures[:]
	result.events = run.events[:]
	result.diagnostics = run.diagnostics[:]
	return
}

destroy :: proc(result: ^Result) {
	if result == nil { return }
	if result.arena != nil {
		mem.dynamic_arena_destroy(result.arena)
		free(result.arena, result.allocator)
	}
	result^ = {}
}
