package driver

import "core:strings"

// Selection follows the official compiler for linux/amd64: build_settings.cpp is_excluded_target_filename
// and parser.cpp parse_build_tag. Subtargets only match generic. #+feature and #+private do not exclude.

@(private = "file")
TARGET_OS :: "linux"

@(private = "file")
TARGET_ARCH :: "amd64"

@(private = "file")
OS_NAMES := []string{"windows", "darwin", "linux", "freebsd", "openbsd", "netbsd", "wasi", "js", "orca", "freestanding"}

@(private = "file")
ARCH_NAMES := []string{"amd64", "i386", "arm32", "arm64", "wasm32", "wasm64p32", "riscv64"}

target_source_excluded :: proc(file_name, source: string, test_mode := false) -> bool {
	return target_name_excluded(file_name) || target_build_lines_excluded(source, test_mode)
}

@(private = "file")
target_name_excluded :: proc(file_name: string) -> bool {
	name := strings.trim_suffix(file_name, ".odin")
	if strings.has_prefix(name, ".") { return true }
	last := strings.last_index_byte(name, '_')
	if last < 0 { return false }
	suffix := name[last + 1:]
	prefix := name[:last]
	middle := prefix[strings.last_index_byte(prefix, '_') + 1:]
	os_suffix, arch_suffix := is_listed(OS_NAMES, suffix), is_listed(ARCH_NAMES, suffix)
	os_middle, arch_middle := is_listed(OS_NAMES, middle), is_listed(ARCH_NAMES, middle)
	switch {
	case os_suffix && arch_middle:
		return !strings.equal_fold(suffix, TARGET_OS) || !strings.equal_fold(middle, TARGET_ARCH)
	case arch_suffix && os_middle:
		return !strings.equal_fold(suffix, TARGET_ARCH) || !strings.equal_fold(middle, TARGET_OS)
	case os_suffix:
		return !strings.equal_fold(suffix, TARGET_OS)
	case arch_suffix:
		return !strings.equal_fold(suffix, TARGET_ARCH)
	}
	return false
}

@(private = "file")
target_build_lines_excluded :: proc(source: string, test_mode: bool) -> bool {
	rest := source
	for line in strings.split_lines_iterator(&rest) {
		text := strings.trim_space(line)
		if strings.has_prefix(text, "package ") { break }
		if strings.has_prefix(text, "#+") && !test_mode && strings.has_prefix(strings.trim_space(text[2:]), "test") { return true }
		if strings.has_prefix(text, "#+build ") && build_line_excluded(text[len("#+build"):]) { return true }
	}
	return false
}

// Comma separates alternatives; whitespace-separated tokens within one alternative must all hold.
@(private = "file")
build_line_excluded :: proc(line: string) -> bool {
	rest := strings.trim_space(line)
	for alternative in strings.split_iterator(&rest, ",") {
		if build_alternative_selected(alternative) { return false }
	}
	return true
}

@(private = "file")
build_alternative_selected :: proc(alternative: string) -> bool {
	rest := alternative
	selected := true
	has_token := false
	for token in strings.fields_iterator(&rest) {
		has_token = true
		negated := strings.has_prefix(token, "!")
		name := token
		if negated { name = token[1:] }
		switch {
		case name == "ignore":
			selected = false
		case name == "bedrock":
			selected = negated
		case:
			matches, known := platform_matches(name)
			selected = selected && known && matches != negated
		}
	}
	return has_token && selected
}

@(private = "file")
platform_matches :: proc(name: string) -> (matches, known: bool) {
	os_name, subtarget := name, ""
	if index := strings.index_byte(name, ':'); index >= 0 {
		os_name, subtarget = name[:index], name[index + 1:]
	}
	if is_listed(OS_NAMES, os_name) {
		generic := subtarget == "" || strings.equal_fold(subtarget, "generic")
		return strings.equal_fold(os_name, TARGET_OS) && generic, true
	}
	if is_listed(ARCH_NAMES, name) { return strings.equal_fold(name, TARGET_ARCH), true }
	return false, false
}

@(private = "file")
is_listed :: proc(names: []string, text: string) -> bool {
	for name in names {
		if strings.equal_fold(name, text) { return true }
	}
	return false
}
