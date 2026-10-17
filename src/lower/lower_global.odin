package lower

import "base:runtime"
import "core:math/big"
import "oc:check"
import "oc:ir"

// Encodes a constant initializer as little-endian bytes of a global of `size` bytes. `ok` is false for constants
// that have no static image (strings, aggregates).
@(private)
global_constant_image :: proc(
	program: ^check.Checked_Program,
	id: check.Const_Id,
	size: u32,
	symbols: []ir.Symbol_Ref,
	relocs: []ir.Data_Reloc,
	allocator: runtime.Allocator,
) -> (
	bytes: []byte,
	out_relocs: []ir.Data_Reloc,
	ok: bool,
	err: runtime.Allocator_Error,
) {
	constant := check.constant(program, id)
	assert(constant != nil)
	bytes = make([]byte, size, allocator) or_return
	out_relocs = relocs
	#partial switch value in constant.value {
	case bool:
		if size > 0 { bytes[0] = u8(value) }
	case big.Int:
		integer := value
		negative, sign_error := big.int_is_negative(&integer, allocator)
		low, low_error := big.int_bitfield_extract(&integer, 0, 64, allocator)
		high, high_error := big.int_bitfield_extract(&integer, 64, 64, allocator)
		if sign_error != .None || low_error != .None || high_error != .None { return nil, nil, false, nil }
		words := [2]u64{u64(low), u64(high)}
		if negative {
			borrow: u64 = 1 if words[0] != 0 else 0
			words[0], words[1] = 0 - words[0], 0 - words[1] - borrow
		}
		write_little_endian(bytes, words[0], words[1])
	case check.Float_Value:
		scalar := ir.Value_Type.F64
		switch size {
		case 2:
			scalar = .F16
		case 4:
			scalar = .F32
		}
		bits, bits_ok := lower_float_bits(value, scalar)
		if !bits_ok { return nil, nil, false, nil }
		write_little_endian(bytes, bits, 0)
	case check.Pointer_Value:
		write_little_endian(bytes, u64(value), 0)
	case check.Nil_Value, check.Uninitialized_Value:
	case check.Address_Value:
		assert(int(value.symbol) > 0 && int(value.symbol) < len(symbols))
		out_relocs = make([]ir.Data_Reloc, len(relocs) + 1, allocator) or_return
		copy(out_relocs, relocs)
		out_relocs[len(relocs)] = {
			offset = 0,
			target = symbols[value.symbol],
			addend = value.addend,
		}
	case:
		return nil, nil, false, nil
	}
	return bytes, out_relocs, true, nil
}

@(private = "file")
write_little_endian :: proc(bytes: []byte, low, high: u64) {
	words := [2]u64{low, high}
	for index in 0 ..< min(len(bytes), 16) {
		bytes[index] = u8(words[index / 8] >> (8 * uint(index % 8)))
	}
}
