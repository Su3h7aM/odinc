package syntax

import "core:strings"

// Vet_Flag is one extra check of the official compiler (build_settings.cpp VetFlags). Flags the official compiler
// has but this one does not implement are rejected by name, never accepted and ignored.
Vet_Flag :: enum u8 {
	Shadowing,
	Using_Stmt,
	Using_Param,
	Style,
	Semicolon,
	Unused_Variables,
	Unused_Imports,
	Unused_Procedures,
	Deprecated,
	Cast,
	Tabs,
	When_Shadowing,
	Explicit_Allocators,
}

Vet_Flags :: bit_set[Vet_Flag;u16]

VET_UNUSED :: Vet_Flags{.Unused_Variables, .Unused_Imports}

// What `-vet` and a bare `#+vet` enable (build_settings.cpp VetFlag_All).
VET_ALL :: VET_UNUSED + {.Shadowing, .Using_Stmt, .Deprecated, .Cast, .When_Shadowing}

// The flags a name stands for in get_vet_flag_from_name, limited to the implemented ones.
vet_flags_from_name :: proc(name: string) -> (flags: Vet_Flags, ok: bool) {
	switch name {
	case "unused":
		return VET_UNUSED, true
	case "unused-variables":
		return {.Unused_Variables}, true
	case "unused-imports":
		return {.Unused_Imports}, true
	case "unused-procedures":
		return {.Unused_Procedures}, true
	case "shadowing":
		return {.Shadowing}, true
	case "using-stmt":
		return {.Using_Stmt}, true
	case "using-param":
		return {.Using_Param}, true
	case "style":
		return {.Style}, true
	case "semicolon":
		return {.Semicolon}, true
	case "deprecated":
		return {.Deprecated}, true
	case "cast":
		return {.Cast}, true
	case "tabs":
		return {.Tabs}, true
	case "when-shadowing":
		return {.When_Shadowing}, true
	case "explicit-allocators":
		return {.Explicit_Allocators}, true
	}
	return {}, false
}

Vet_Tag_Error :: enum u8 {
	None,
	Expected_Space,
	Expected_Flag_Name,
	Invalid_Flag,
}

// Applies the body of a `#+vet` tag (the text after `#+vet`) to `base`, as parse_vet_tag does: a bare tag adds
// everything in VET_ALL, a name adds its flags and `!name` removes them. Parsing stops at the first error.
parse_vet_tag :: proc(body: string, base: Vet_Flags) -> (flags: Vet_Flags, err: Vet_Tag_Error, invalid_name: string) {
	flags = base
	if len(body) > 0 && body[0] != ' ' && body[0] != '\t' {
		return flags, .Expected_Space if strings.trim_space(body) != "" else .None, ""
	}
	rest := strings.trim_space(body)
	if len(rest) == 0 { return flags + VET_ALL, .None, "" }
	for len(strings.trim_space(rest)) > 0 {
		name: string
		name, rest = next_flag_name(rest, false)
		name = strings.trim_space(name)
		if len(name) == 0 { break }
		notted := name[0] == '!'
		if notted {
			name = name[1:]
			if len(name) == 0 { return flags, .Expected_Flag_Name, "" }
		}
		named, found := vet_flags_from_name(name)
		if !found { return flags, .Invalid_Flag, name }
		flags = flags - named if notted else flags + named
	}
	return flags, .None, ""
}

// The flags of a file with no `#+vet` tag: those of the command line, but only in the packages `-vet-packages` names.
// An empty list names every package.
vet_flags_for_package :: proc(options: Parse_Options, package_name: string) -> Vet_Flags {
	if len(options.vet_packages) == 0 { return options.vet }
	for name in options.vet_packages {
		if name == package_name { return options.vet }
	}
	return {}
}
