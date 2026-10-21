package main

import "core:fmt"

// Direct swizzles over an array-element #soa: reads, scatter writes,
// read-modify-write and range over a swizzle. The output is byte-identical to
// the official compiler's output for the same fixture.
main :: proc() {
	ref := [4]u16{1, 2, 3, 4}

	fixed: #soa[3][4]u16
	fixed.x[0], fixed.y[0], fixed.z[0], fixed.w[0] = 90, 91, 92, 93
	fixed.x[1], fixed.y[1], fixed.z[1], fixed.w[1] = 1, 2, 3, 4

	fmt.println(fixed[1].x, ref.x)
	fmt.println(fixed[1].xy, ref.xy)
	fmt.println(fixed[1].xyz, ref.xyz)
	fmt.println(fixed[1].xyzw, ref.xyzw)
	fmt.println(fixed[1].yx, ref.yx)
	fmt.println(fixed[1].xx, ref.xx)
	fmt.println(fixed[1].wzyx, ref.wzyx)

	i := 1
	fmt.println(fixed[i].xy, ref.xy)

	fixed[1].xy = [2]u16{10, 11}
	fmt.println(fixed.x[1], fixed.y[1], fixed.z[1])
	fixed[1].yx = [2]u16{20, 21}
	fmt.println(fixed.y[1], fixed.x[1], fixed.x[0], fixed.w[0])

	dyn := make(#soa[dynamic][4]u16, 2)
	defer delete(dyn)
	dyn[0] = [4]u16{1, 2, 3, 4}
	dyn[1] = [4]u16{5, 6, 7, 8}
	fmt.println(dyn[0].xy, ref.xy)
	fmt.println(dyn[0].zx, ref.zx)
	dyn[1].xy = [2]u16{40, 41}
	fmt.println(dyn.x[1], dyn.y[1], dyn.x[0])

	s := dyn[:]
	fmt.println(s[0].zw, ref.zw)
	s[0].zw = [2]u16{50, 51}
	fmt.println(dyn.z[0], dyn.w[0])

	fixed[1].xy += [2]u16{9, 10}
	fmt.println(fixed.x[1], fixed.y[1])
	fixed[1].xx += [2]u16{5, 100}
	fmt.println(fixed.x[1])

	sum: u16
	for c in fixed[1].wz {
		sum += c
	}
	fmt.println(sum)

	fixed[1].xy = [2]u16{9, 10}
	fixed[1].xy = fixed[1].yx
	fmt.println(fixed[1].xy)
}
