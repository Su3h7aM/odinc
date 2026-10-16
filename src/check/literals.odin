package check

import "base:runtime"
import "core:math/big"
import "core:strconv"
import "oc:syntax"
import "oc:types"

Literal_Diagnostic :: enum u8 {
	None,
	Invalid_Integer_Literal,
	Invalid_Float_Literal,
	Invalid_Rune_Literal,
	Invalid_Token_Literal,
}
Literal_Error :: union #shared_nil {
	Literal_Diagnostic,
	Constant_Error,
	runtime.Allocator_Error,
	big.Error,
}

BIG_INT_LITERAL_MAX_EXPONENT :: 512
BIG_RAT_LITERAL_MAX_EXPONENT :: 65536

// Parses one numeric/rune token slice into the caller-owned constant pool.
@(require_results)
literal_constant :: proc(pool: ^Constant_Pool, kind: syntax.Token_Kind, text: string, type: types.Type_Id = 0) -> (id: Const_Id, err: Literal_Error) {
	#partial switch kind {
	case .Integer:
		return literal_integer(pool, text, type)
	case .Float:
		return literal_float(pool, text)
	case .Imag:
		return literal_imaginary(pool, text)
	case .Rune:
		return literal_rune(pool, text, type)
	case:
		return 0, Literal_Diagnostic.Invalid_Token_Literal
	}
}

literal_error_message :: proc(err: Literal_Error) -> string {
	if diagnostic, ok := err.(Literal_Diagnostic); ok {
		switch diagnostic {
		case .None:
			return ""
		case .Invalid_Integer_Literal:
			return "Invalid integer literal"
		case .Invalid_Float_Literal:
			return "Invalid float literal"
		case .Invalid_Rune_Literal:
			return "Invalid rune literal"
		case .Invalid_Token_Literal:
			return "Invalid token literal"
		case:
			return ""
		}
	}
	return ""
}

@(private = "file")
literal_integer :: proc(pool: ^Constant_Pool, text: string, type: types.Type_Id) -> (id: Const_Id, err: Literal_Error) {
	base := i8(10)
	prefix_length := 0
	if len(text) > 2 && text[0] == '0' {
		switch text[1] {
		case 'b':
			base, prefix_length = 2, 2
		case 'o':
			base, prefix_length = 8, 2
		case 'd':
			base, prefix_length = 10, 2
		case 'z':
			base, prefix_length = 12, 2
		case 'x':
			base, prefix_length = 16, 2
		}
	}

	digit_end := len(text)
	exponent := 0
	if base == 10 {
		for i in prefix_length ..< len(text) {
			if text[i] == 'e' || text[i] == 'E' {
				digit_end = i
				valid: bool
				exponent, valid = literal_positive_exponent(text[i + 1:], BIG_INT_LITERAL_MAX_EXPONENT)
				if !valid { return 0, Literal_Diagnostic.Invalid_Integer_Literal }
				break
			}
		}
	}

	mantissa := text[prefix_length:digit_end]
	if !literal_has_digit(mantissa, base) { return 0, Literal_Diagnostic.Invalid_Integer_Literal }
	temporary_allocator := context.temp_allocator
	clean_mantissa, allocation_error := literal_remove_underscores(mantissa, temporary_allocator)
	if allocation_error != nil { return 0, allocation_error }
	value: big.Int
	parse_error := big.int_atoi(&value, clean_mantissa, base, allocator = temporary_allocator)
	if parse_error == big.Error.Invalid_Argument { return 0, Literal_Diagnostic.Invalid_Integer_Literal }
	if parse_error != nil { return 0, parse_error }
	defer big.int_destroy(&value)

	if exponent > 0 {
		factor, power_error := literal_power_of_ten(exponent, temporary_allocator)
		if power_error != nil { return 0, power_error }
		defer big.int_destroy(&factor)
		if multiply_error := big.int_mul(&value, &value, &factor, allocator = temporary_allocator); multiply_error != nil {
			return 0, multiply_error
		}
	}
	return constant_pool_intern_integer(pool, &value, type)
}

@(private = "file")
literal_float :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, err: Literal_Error) {
	if len(text) > 2 && text[0] == '0' && text[1] == 'h' {
		return literal_hex_float(pool, text)
	}
	if !literal_contains(text, '.') && !literal_contains(text, '-') {
		return literal_integer(pool, text, 0)
	}
	return literal_decimal_rational(pool, text)
}

@(private = "file")
literal_decimal_rational :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, err: Literal_Error) {
	temporary_allocator := context.temp_allocator
	digits, allocation_error := make([]u8, len(text), temporary_allocator)
	if allocation_error != nil { return 0, allocation_error }
	written := 0
	fraction_digits := 0
	seen_point := false
	seen_digit := false
	index := 0
	negative := false
	if len(text) > 0 && (text[0] == '+' || text[0] == '-') {
		negative = text[0] == '-'
		index = 1
	}

	for index < len(text) && text[index] != 'e' && text[index] != 'E' {
		c := text[index]
		index += 1
		if c == '_' { continue }
		if c == '.' {
			if seen_point { return 0, Literal_Diagnostic.Invalid_Float_Literal }
			seen_point = true
			continue
		}
		if c < '0' || c > '9' { return 0, Literal_Diagnostic.Invalid_Float_Literal }
		digits[written] = c
		written += 1
		seen_digit = true
		if seen_point { fraction_digits += 1 }
	}
	if !seen_digit { return 0, Literal_Diagnostic.Invalid_Float_Literal }

	exponent := 0
	if index < len(text) {
		index += 1
		exponent_text := text[index:]
		negative_exponent, valid: bool
		exponent, negative_exponent, valid = literal_signed_exponent(exponent_text, BIG_RAT_LITERAL_MAX_EXPONENT)
		if !valid { return 0, Literal_Diagnostic.Invalid_Float_Literal }
		if negative_exponent { exponent = -exponent }
	}
	net_exponent := exponent - fraction_digits
	if net_exponent > BIG_RAT_LITERAL_MAX_EXPONENT || net_exponent < -BIG_RAT_LITERAL_MAX_EXPONENT {
		return 0, Literal_Diagnostic.Invalid_Float_Literal
	}

	mantissa: big.Int
	parse_error := big.int_atoi(&mantissa, string(digits[:written]), 10, allocator = temporary_allocator)
	if parse_error != nil { return 0, parse_error }
	defer big.int_destroy(&mantissa)
	is_zero, zero_error := big.is_zero(&mantissa, allocator = temporary_allocator)
	if zero_error != nil { return 0, zero_error }
	if is_zero {
		return constant_pool_intern_float(pool, Float_Value{bits = 0, width = 64})
	}
	if negative { mantissa.sign = .Negative }

	numerator, denominator: big.Int
	defer big.int_destroy(&numerator, &denominator)
	big.int_copy(&numerator, &mantissa, allocator = temporary_allocator) or_return
	big.int_set_from_integer(&denominator, 1, allocator = temporary_allocator) or_return
	if net_exponent != 0 {
		power, power_error := literal_power_of_ten(abs(net_exponent), temporary_allocator)
		if power_error != nil { return 0, power_error }
		defer big.int_destroy(&power)
		if net_exponent > 0 {
			if multiply_error := big.int_mul(&numerator, &numerator, &power, allocator = temporary_allocator); multiply_error != nil {
				return 0, multiply_error
			}
		} else {
			big.int_copy(&denominator, &power, allocator = temporary_allocator) or_return
		}
	}

	value: big.Rat
	defer big.destroy(&value)
	big.rat_set_frac_int(&value, &numerator, &denominator, allocator = temporary_allocator) or_return
	return constant_pool_intern_rational(pool, &value)
}

@(private = "file")
literal_hex_float :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, err: Literal_Error) {
	bits, digit_count, ok := literal_hex_bits(text[2:])
	if !ok || (digit_count != 4 && digit_count != 8 && digit_count != 16) {
		return 0, Literal_Diagnostic.Invalid_Float_Literal
	}
	value: f64
	switch digit_count {
	case 4:
		value = f64(transmute(f16)u16(bits))
	case 8:
		value = f64(transmute(f32)u32(bits))
	case 16:
		value = transmute(f64)bits
	}
	return constant_pool_intern_float(pool, Float_Value{bits = transmute(u64)value, width = 64})
}

@(private = "file")
literal_imaginary :: proc(pool: ^Constant_Pool, text: string) -> (id: Const_Id, err: Literal_Error) {
	if len(text) < 2 { return 0, Literal_Diagnostic.Invalid_Token_Literal }
	if text[len(text) - 1] != 'i' && text[len(text) - 1] != 'j' && text[len(text) - 1] != 'k' {
		return 0, Literal_Diagnostic.Invalid_Token_Literal
	}
	magnitude_id, magnitude_error := literal_float(pool, text[:len(text) - 1])
	if magnitude_error != nil {
		if _, diagnostic := magnitude_error.(Literal_Diagnostic); diagnostic {
			return 0, Literal_Diagnostic.Invalid_Token_Literal
		}
		return 0, magnitude_error
	}
	zero: big.Int
	big.int_set_from_integer(&zero, 0, allocator = context.temp_allocator) or_return
	defer big.int_destroy(&zero)
	zero_id, zero_error := constant_pool_intern_integer(pool, &zero)
	if zero_error != nil { return 0, zero_error }
	switch text[len(text) - 1] {
	case 'i':
		return constant_pool_intern_complex(pool, Complex_Value{zero_id, magnitude_id})
	case 'j':
		return constant_pool_intern_quaternion(pool, Quaternion_Value{zero_id, zero_id, magnitude_id, zero_id})
	case 'k':
		return constant_pool_intern_quaternion(pool, Quaternion_Value{zero_id, zero_id, zero_id, magnitude_id})
	case:
		return 0, Literal_Diagnostic.Invalid_Token_Literal
	}
}

@(private = "file")
literal_rune :: proc(pool: ^Constant_Pool, text: string, type: types.Type_Id) -> (id: Const_Id, err: Literal_Error) {
	if len(text) < 3 || text[0] != '\'' || text[len(text) - 1] != '\'' {
		return 0, Literal_Diagnostic.Invalid_Rune_Literal
	}
	r, _, tail, ok := strconv.unquote_char(text[1:len(text) - 1], '\'')
	if !ok || len(tail) != 0 { return 0, Literal_Diagnostic.Invalid_Rune_Literal }
	value: big.Int
	big.int_set_from_integer(&value, i64(r), allocator = context.temp_allocator) or_return
	defer big.int_destroy(&value)
	return constant_pool_intern_integer(pool, &value, type)
}

@(private = "file")
literal_hex_bits :: proc(text: string) -> (bits: u64, digit_count: int, ok: bool) {
	for c in text {
		if c == '_' { continue }
		digit: u8
		switch c {
		case '0' ..= '9':
			digit = u8(c - '0')
		case 'a' ..= 'f':
			digit = u8(c - 'a') + 10
		case 'A' ..= 'F':
			digit = u8(c - 'A') + 10
		case:
			return 0, 0, false
		}
		if digit_count == 16 { return 0, 0, false }
		bits = bits << 4 | u64(digit)
		digit_count += 1
	}
	return bits, digit_count, digit_count > 0
}

@(private = "file")
literal_positive_exponent :: proc(text: string, limit: int) -> (exponent: int, ok: bool) {
	if len(text) == 0 { return 0, false }
	index := 0
	if text[0] == '+' { index = 1 }
	if index == len(text) { return 0, false }
	has_digit := false
	for c in text[index:] {
		if c == '_' { continue }
		if c < '0' || c > '9' { return 0, false }
		has_digit = true
		exponent = exponent * 10 + int(c - '0')
		if exponent > limit { return 0, false }
	}
	return exponent, has_digit
}

@(private = "file")
literal_signed_exponent :: proc(text: string, limit: int) -> (exponent: int, negative, ok: bool) {
	if len(text) == 0 { return 0, false, false }
	index := 0
	if text[0] == '+' || text[0] == '-' {
		negative = text[0] == '-'
		index = 1
	}
	if index == len(text) { return 0, false, false }
	has_digit := false
	for c in text[index:] {
		if c == '_' { continue }
		if c < '0' || c > '9' { return 0, false, false }
		has_digit = true
		exponent = exponent * 10 + int(c - '0')
		if exponent > limit { return 0, false, false }
	}
	return exponent, negative, has_digit
}

@(private = "file")
literal_power_of_ten :: proc(exponent: int, allocator: runtime.Allocator) -> (value: big.Int, err: big.Error) {
	ten: big.Int
	big.int_set_from_integer(&ten, 10, allocator = allocator) or_return
	defer big.int_destroy(&ten)
	big.int_pow(&value, &ten, exponent, allocator = allocator) or_return
	return
}

@(private = "file")
literal_has_digit :: proc(text: string, base: i8) -> bool {
	for c in text {
		if c == '_' { continue }
		digit := -1
		switch c {
		case '0' ..= '9':
			digit = int(c - '0')
		case 'a' ..= 'z':
			digit = int(c - 'a') + 10
		case 'A' ..= 'Z':
			digit = int(c - 'A') + 10
		}
		if digit >= 0 && digit < int(base) { return true }
	}
	return false
}

@(private = "file")
literal_contains :: proc(text: string, character: rune) -> bool {
	for c in text {
		if c == character { return true }
	}
	return false
}

@(private = "file")
literal_remove_underscores :: proc(text: string, allocator: runtime.Allocator) -> (cleaned: string, err: runtime.Allocator_Error) {
	buffer: []u8
	buffer, err = make([]u8, len(text), allocator)
	if err != nil { return "", err }
	length := 0
	for i in 0 ..< len(text) {
		character := text[i]
		if character == '_' { continue }
		buffer[length] = character
		length += 1
	}
	return string(buffer[:length]), nil
}
