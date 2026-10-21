package main

print_id :: proc(id: typeid) {  }

main :: proc() {
	print_id(type_info_of(int))
}
