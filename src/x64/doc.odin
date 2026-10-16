// Package x64 is a machine-code encoder for the x86-64 (AMD64) instruction set
// under the Linux System V ABI. It is the lowest layer of the x64 backend: it
// turns explicit operands into bytes and nothing else.
//
// Encoding is a deterministic function of its arguments: this package performs
// no instruction selection, no register allocation, and no allocation of its
// own beyond the byte buffer owned by an Emitter.
//
// An Emitter owns a [dynamic]byte created with emitter_init. Branches target
// Label handles created with label_new, bound with label_bind, referenced with
// label_use, and back-patched with label_resolve.
//
// Ill-formed operands trip an assert; instruction selection above this package
// is responsible for producing well-formed operands.
package x64
