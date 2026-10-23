package syntax

import "core:strings"

Analysis :: enum u8 {
	Escape,
	Atomic,
}

Analysis_Flags :: bit_set[Analysis;u8]

ANALYSIS_ALL :: Analysis_Flags{.Escape, .Atomic}

Analysis_Tag_Error :: enum u8 {
	None,
	Expected_Space,
	Expected_Name,
	Invalid_Name,
}

// Matches parse_analysis_tag in upstream parser.cpp; each tag starts from the preceding effective flags.
parse_analysis_tag :: proc(body: string, base: Analysis_Flags) -> (flags: Analysis_Flags, err: Analysis_Tag_Error, invalid_name: string) {
	flags = base
	if len(body) > 0 && body[0] != ' ' && strings.trim_space(body) != "" {
		return flags, .Expected_Space, ""
	}
	rest := strings.trim_space(body)
	if len(rest) == 0 { return flags + ANALYSIS_ALL, .None, "" }
	for len(strings.trim_space(rest)) > 0 {
		name: string
		name, rest = next_flag_name(rest, false)
		name = strings.trim_space(name)
		if len(name) == 0 { break }
		notted := name[0] == '!'
		if notted {
			name = name[1:]
			if len(name) == 0 { return flags, .Expected_Name, "" }
		}
		flag: Analysis
		switch name {
		case "escape":
			flag = .Escape
		case "atomic":
			flag = .Atomic
		case:
			return flags, .Invalid_Name, name
		}
		flags = flags - {flag} if notted else flags + {flag}
	}
	return flags, .None, ""
}

apply_analysis_tag :: proc(p: ^Parser, start: u32, text: string) {
	flags, err, invalid_name := parse_analysis_tag(text[len("#+analysis"):], p.ast.analysis)
	switch err {
	case .None:
	case .Expected_Space:
		report(p, .Expected_Space_After_Analysis, start)
	case .Expected_Name:
		report(p, .Expected_Analysis_Name, start)
	case .Invalid_Name:
		report(p, .Invalid_Analysis_Name, start)
		p.errors[len(p.errors) - 1].detail = invalid_name
	}
	p.ast.analysis = flags
}
