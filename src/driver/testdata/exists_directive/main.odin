package exists_directive

LIB :: ("missing.lib" when ODIN_OS == .Windows else "main.odin" when ODIN_OS == .Linux else "")

when LIB != "" {
	when !#exists(LIB) {
		#panic("sibling file not found")
	}
}

when #exists("missing.lib") {
	#panic("missing file reported as present")
}

main :: proc() {
}
