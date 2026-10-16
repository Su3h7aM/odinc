/*
	Writes ELF64 little-endian x86-64 relocatable objects (.o).

	The package mirrors the ELF specification types one to one (packed structs
	and the spec's constants) and builds the object file through a `Builder`:
	add sections, symbols, and relocations, then serialize with
	`builder_write`.  The writer produces `.symtab`, `.strtab`, `.shstrtab`,
	and `.rela.<section>` sections automatically, keeps local symbols before
	global symbols in `.symtab`, and sets every `sh_link`/`sh_info` pair
	accordingly.

	Executable output (ET_EXEC) is not in scope here.

	Memory rules:
	- `builder_init` stores the allocator; `builder_destroy` frees everything
	  the builder owns with that same allocator.
	- `builder_write` allocates the returned bytes and all scratch with the
	  allocator given to it; the caller owns the result and must `delete` it
	  with the same allocator.
	- Section and symbol names are cloned into the builder; arguments passed
	  in stay owned by the caller.

	Determinism: serialization iterates arrays strictly in insertion order
	and emits operators in a fixed sequence, so the same builder contents
	always produce byte-identical output.  No timestamps, no pointer-order
	dependence, no map iteration anywhere in the file path.
*/
package elf
