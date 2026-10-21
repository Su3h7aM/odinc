package main

import "base:intrinsics"

echo :: proc "contextless" (a: [$N]$T, b: [N]T) -> T {
	return b[0]
}

combine :: proc "contextless" (a: [$N]int, b: [N][$P]int) -> int {
	return N + P
}

deep :: proc "contextless" (a: [$N]int, b: [N][$P][2]int) -> int {
	return N + P
}

shared :: proc "contextless" (a: [$N]$T, b: [N]T, c: T) -> T {
	return c
}

constant_dimension :: proc "contextless" (a: [$N]int, b: [N][2 + 1]int) -> int {
	return N
}

matrix_mul :: proc "contextless" (a: [$M][$N]$T, b: [N][$P]T) -> (c: [M][P]T) {
	for i in 0 ..< M {
		for j in 0 ..< P {
			for k in 0 ..< N {
				c[i][j] += a[i][k] * b[k][j]
			}
		}
	}
	return
}

Table :: struct($K, $V: typeid) {
	n: int,
}

expand :: proc "contextless" (table: ^$T/Table) -> int {
	return table.n
}

main :: proc() {
	code := 0
	a := [2]int{1, 2}
	if echo(a, [2]int{3, 4}) == 3 && combine(a, [2][3]int{}) == 5 { code += 1 }
	if deep(a, [2][3][2]int{}) == 5 { code += 2 }
	x := [2][3]f32{{1, 2, 3}, {3, 2, 1}}
	y := [3][2]f32{{0, 8}, {6, 2}, {8, 4}}
	product := matrix_mul(x, y)
	if product[0][0] == 36 && product[0][1] == 24 && product[1][0] == 20 && product[1][1] == 32 { code += 4 }
	table := Table(int, string) {
		n = 7,
	}
	if expand(&table) == 7 { code += 8 }
	if shared(a, [2]int{3, 4}, 9) == 9 { code += 16 }
	if constant_dimension(a, [2][3]int{}) == 2 { code += 32 }
	if combine([2]int{}, [2][3]int{}) == 5 && combine([3]int{}, [3][4]int{}) == 7 { code += 64 }
	foo :: proc "contextless" ($N: $I, $T: typeid) -> (res: [N]T) {
		for i in 0 ..< N {
			res[i] = T(i * i)
		}
		return
	}
	squares := foo(4, int)
	if squares[0] == 0 && squares[1] == 1 && squares[2] == 4 && squares[3] == 9 { code += 128 }
	intrinsics.syscall(60, uintptr(code))
}
