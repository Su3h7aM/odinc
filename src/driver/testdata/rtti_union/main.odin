package main

import "base:runtime"
import "core:fmt"

Value :: union {
	int,
	f64,
}
Record :: struct {
	value: int,
}
Choice :: enum {
	First,
	Second,
}
Flags :: bit_field u8 {
	low:  u8 | 3,
	high: u8 | 5,
}
Box :: struct($T: typeid) {
	value: T,
}
Number :: distinct int

print_name :: proc($T: typeid) {
	named := type_info_of(T).variant.(runtime.Type_Info_Named)
	fmt.println(named.name, named.pkg, type_info_of(T).id == typeid_of(T))
}

main :: proc() {
	value: Value = 42
	info := type_info_of(Value).variant.(runtime.Type_Info_Named)
	info_union := info.base.variant.(runtime.Type_Info_Union)
	fmt.println(value)
	fmt.println(info_union.tag_type == type_info_of(u64), info_union.tag_offset)
	record := Record{7}
	choice := Choice.Second
	flags := Flags {
		low  = 3,
		high = 5,
	}
	box := Box(int){9}
	number := Number(11)
	fmt.printf("%v %T\n", value, value)
	fmt.printf("%v %T\n", record, record)
	fmt.printf("%v %T\n", choice, choice)
	fmt.printf("%v %T\n", flags, flags)
	fmt.printf("%v %T\n", box, box)
	fmt.printf("%v %T\n", number, number)
	print_name(Value)
	print_name(Record)
	print_name(Choice)
	print_name(Flags)
	print_name(type_of(box))
	print_name(Number)
	Local_Record :: struct {
		value: int,
	}
	Local_Value :: union {
		int,
		bool,
	}
	Local_Choice :: enum {
		First,
		Second,
	}
	Local_Flags :: bit_field u8 {
		value: u8 | 8,
	}
	Local_Number :: distinct int
	local_record := Local_Record{13}
	local_value: Local_Value = 15
	local_choice := Local_Choice.Second
	local_flags := Local_Flags {
		value = 17,
	}
	local_number := Local_Number(19)
	fmt.printf("%v %T\n", local_record, local_record)
	fmt.printf("%v %T\n", local_value, local_value)
	fmt.printf("%v %T\n", local_choice, local_choice)
	fmt.printf("%v %T\n", local_flags, local_flags)
	fmt.printf("%v %T\n", local_number, local_number)
	print_name(Local_Record)
	print_name(Local_Value)
	print_name(Local_Choice)
	print_name(Local_Flags)
	print_name(Local_Number)
}
