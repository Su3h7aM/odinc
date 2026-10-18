package main

import "base:intrinsics"

Vec2 :: struct {
	x, y: int,
}

Entity :: struct {
	position: Vec2,
	health:   int,
}

main :: proc() {
	entity := Entity {
		position = {x = 3, y = 4},
		health = 5,
	}
	pointer := &entity
	pointer.position.y += 1
	intrinsics.syscall(60, uintptr(entity.position.x + entity.position.y + entity.health))
}
