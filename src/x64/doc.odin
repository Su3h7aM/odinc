// Package x64 is a machine-code encoder for the x86-64 (AMD64) instruction set
// under the Linux System V ABI. It is the lowest layer of the x64 backend: it
// turns explicit operands into bytes and nothing else.
//
// Encoding is a total, deterministic function of its arguments. Every operand
// is supplied by the caller: this package performs no instruction selection,
// no register allocation, and no allocation of its own beyond the byte buffer
// owned by an Emitter. The same sequence of calls always produces the same
// bytes.
//
// # Operands
//
// General-purpose registers are 8, 16, 32 or 64 bits wide; a Reg carries that
// width, so an instruction reads its operand size from the register operand.
// XMM registers are supported for the SSE2 scalar instructions. Memory
// operands are base + index*scale + displacement, or RIP-relative with a
// relocation marker.
//
// # Emitter and labels
//
// An Emitter owns a [dynamic]byte and appends to it. It is created with
// emitter_init, which takes the backing allocator explicitly, and released with
// emitter_destroy. Branches are emitted against Label handles created with
// label_new, bound with label_bind, and referenced with label_use; label_resolve
// back-patches every reference. Jumps always use rel32 displacements in this
// slice.
//
// # Contract
//
// Ill-formed operands — mismatched register widths, a REG_NONE where a register
// is required, RSP used as an index, an unbound label at resolve time — violate
// a precondition and trip an assert. Instruction selection above this package
// is responsible for producing well-formed operands.
package x64
