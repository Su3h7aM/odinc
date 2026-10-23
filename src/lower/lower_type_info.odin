package lower

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "oc:check"
import "oc:ir"
import "oc:syntax"
import "oc:types"

@(private)
TYPE_TABLE_GLOBAL_NAME :: "runtime.type_table"

// Bit positions of Type_Info_Struct_Flags, in the order of the runtime enum.
@(private)
STRUCT_FLAG_PACKED :: 0
@(private)
STRUCT_FLAG_RAW_UNION :: 1
@(private)
STRUCT_FLAG_ALIGN :: 3

@(private)
Type_Info_Writer :: struct {
	store:           ^types.Store,
	module:          ^ir.Module,
	symbols:         []ir.Symbol_Ref,
	map_info:        []check.Map_Info_Entry,
	allocator:       runtime.Allocator,
	entries:         []check.Type_Info_Entry,
	representatives: []types.Type_Id,
	enum_members:    []check.Enum_Type_Members,
	info_type:       types.Type_Id,
	parameters_type: types.Type_Id,
	info_size:       i64,
	first:           u32,
	union_offset:    i64,
	union_type:      types.Type_Id,
	variant_block:   i64,
	tag_size:        i64,
	image_count:     int,
	names_in_use:    map[string]struct{},
	// Content key of every image already appended, so equal arrays and strings share one global.
	images:          map[string]int,
}

// Bytes and relocations of one global under construction. `base` is where the current struct starts in `bytes`.
@(private)
Type_Info_Image :: struct {
	bytes:  []byte,
	relocs: [dynamic]ir.Data_Reloc,
	base:   i64,
}

// Every product of the writer and its name and content-key maps live in the module arena, which the module frees.
@(private)
init_type_info_writer :: proc(writer: ^Type_Info_Writer, module: ^ir.Module) {
	writer.module = module
	writer.allocator = virtual.arena_allocator(&module.arena)
	writer.names_in_use = module_symbol_names(module, writer.allocator)
	writer.images = make(map[string]int, writer.allocator)
}

// Writes the runtime type info entries and the runtime `type_table` slice from the checked entries.
@(private)
fill_type_info :: proc(
	program: ^check.Checked_Program,
	module: ^ir.Module,
	symbols: []ir.Symbol_Ref,
	errors: ^[dynamic]Lower_Error,
) -> (
	err: runtime.Allocator_Error,
) {
	requirements := check.runtime_requirements(program)
	if len(requirements.type_info) == 0 { return nil }
	store := check.type_store(program)
	if requirements.type_info_type == types.TYPE_NONE {
		append(errors, Lower_Error{code = .Unsupported, feature = .Runtime_Type_Info}) or_return
		return nil
	}
	size, alignment, layout_error := types.layout(store, requirements.type_info_type)
	assert(layout_error == .None, "runtime Type_Info layout is incomplete")
	union_offset, union_type := field_location(store, requirements.type_info_type, "variant")
	union_layout, union_error := types.union_layout(store, union_type)
	assert(union_error == .None, "runtime Type_Info variant layout is incomplete")
	writer := Type_Info_Writer {
		store           = store,
		symbols         = symbols,
		map_info        = requirements.map_info,
		entries         = requirements.type_info,
		representatives = requirements.type_info_representatives,
		enum_members    = requirements.enum_members,
		info_type       = requirements.type_info_type,
		parameters_type = requirements.type_info_parameters_type,
		info_size       = size,
		first           = u32(len(module.globals)),
		union_offset    = union_offset,
		union_type      = union_type,
		variant_block   = union_layout.variant_block_size,
		tag_size        = union_layout.tag_size,
	}
	init_type_info_writer(&writer, module)
	for entry in requirements.type_info {
		name := generated_global_name(&writer, "entry", u64(entry.slot))
		append(&module.globals, ir.Global{name = name, size = u32(size), align = u32(alignment), anonymous = true}) or_return
	}
	for index in 0 ..< len(requirements.type_info) {
		image, supported := type_info_image(&writer, index) or_return
		if !supported {
			append(errors, Lower_Error{code = .Unsupported, feature = .Runtime_Type_Info}) or_return
		}
		global := &module.globals[int(writer.first) + index]
		global.bytes = image.bytes
		global.relocs = image.relocs[:]
	}
	return fill_type_table(&writer)
}

// Official lb_setup_type_info_data_giant_array reserves slot zero for a zeroed Type_Info.
@(private)
fill_type_table :: proc(writer: ^Type_Info_Writer) -> runtime.Allocator_Error {
	slice_index := -1
	for global, index in writer.module.globals {
		if global.name == TYPE_TABLE_GLOBAL_NAME { slice_index = index }
	}
	if slice_index < 0 { return nil }
	sentinel_index := len(writer.module.globals)
	sentinel := make_image(writer, writer.info_type) or_return
	append(
		&writer.module.globals,
		ir.Global {
			name = generated_global_name(writer, "invalid", 0),
			bytes = sentinel.bytes,
			size = u32(len(sentinel.bytes)),
			align = u32(writer.module.globals[writer.first].align),
			anonymous = true,
		},
	) or_return
	count := len(writer.entries)
	table := ir.Global {
		name      = generated_global_name(writer, "table", 0),
		size      = u32(8 * (count + 1)),
		align     = 8,
		anonymous = true,
	}
	table.bytes = make([]byte, 8 * (count + 1), writer.allocator) or_return
	table.relocs = make([]ir.Data_Reloc, count + 1, writer.allocator) or_return
	table.relocs[0] = {
		offset = 0,
		target = {.Global, u32(sentinel_index)},
	}
	for index in 0 ..< count {
		table.relocs[index + 1] = {
			offset = u32(8 * (index + 1)),
			target = {.Global, writer.first + u32(index)},
		}
	}
	table_index := len(writer.module.globals)
	append(&writer.module.globals, table) or_return
	slice := &writer.module.globals[slice_index]
	slice.bytes = make([]byte, 16, writer.allocator) or_return
	slice.relocs = make([]ir.Data_Reloc, 1, writer.allocator) or_return
	slice.relocs[0] = {
		offset = 0,
		target = {.Global, u32(table_index)},
	}
	write_scalar(slice.bytes, 8, u64(count + 1), 8)
	return nil
}

// Returns false when the entry needs a runtime kind that the lowering does not write yet.
@(private)
type_info_image :: proc(writer: ^Type_Info_Writer, index: int) -> (image: Type_Info_Image, supported: bool, err: runtime.Allocator_Error) {
	entry := writer.entries[index]
	image = make_image(writer, writer.info_type) or_return
	write_scalar_field(writer, &image, writer.info_type, "size", u64(entry.size), 8)
	write_scalar_field(writer, &image, writer.info_type, "align", u64(entry.alignment), 8)
	write_scalar_field(writer, &image, writer.info_type, "id", entry.runtime_id, 8)
	supported, err = write_type_info_variant(writer, &image, entry)
	return image, supported, err
}

@(private)
write_type_info_variant :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	entry: check.Type_Info_Entry,
) -> (
	supported: bool,
	err: runtime.Allocator_Error,
) {
	store := writer.store
	descriptor := types.get(store, entry.type)^
	if entry.name != "" {
		payload := begin_variant(writer, image, "Type_Info_Named")
		set_string_field(writer, image, payload, "name", entry.name) or_return
		set_string_field(writer, image, payload, "pkg", entry.pkg) or_return
		if entry.base_slot != 0 {
			return true, set_pointer_field(writer, image, payload, "base", int(writer.first + entry.base_slot - 1))
		}
		return write_entry_pointer(writer, image, payload, "base", descriptor.elem)
	}
	if descriptor.kind == .Named {
		payload := begin_variant(writer, image, "Type_Info_Named")
		set_string_field(writer, image, payload, "name", descriptor.name) or_return
		return write_entry_pointer(writer, image, payload, "base", descriptor.elem)
	}
	#partial switch descriptor.kind {
	case .Integer:
		payload := begin_variant(writer, image, "Type_Info_Integer")
		write_scalar_field(writer, image, payload, "signed", u64(descriptor.signed), 1)
		return true, nil
	case .Rune:
		begin_variant(writer, image, "Type_Info_Rune")
		return true, nil
	case .Float:
		begin_variant(writer, image, "Type_Info_Float")
		return true, nil
	case .Complex:
		begin_variant(writer, image, "Type_Info_Complex")
		return true, nil
	case .Quaternion:
		begin_variant(writer, image, "Type_Info_Quaternion")
		return true, nil
	case .Bool:
		begin_variant(writer, image, "Type_Info_Boolean")
		return true, nil
	case .Any:
		begin_variant(writer, image, "Type_Info_Any")
		return true, nil
	case .Type_Id:
		begin_variant(writer, image, "Type_Info_Type_Id")
		return true, nil
	case .String, .String16, .CString, .CString16:
		payload := begin_variant(writer, image, "Type_Info_String")
		is_cstring := descriptor.kind == .CString || descriptor.kind == .CString16
		is_utf_16 := descriptor.kind == .String16 || descriptor.kind == .CString16
		write_scalar_field(writer, image, payload, "is_cstring", u64(is_cstring), 1)
		write_scalar_field(writer, image, payload, "encoding", u64(is_utf_16), 1)
		return true, nil
	case .Pointer, .Raw_Pointer:
		payload := begin_variant(writer, image, "Type_Info_Pointer")
		return write_entry_pointer(writer, image, payload, "elem", descriptor.elem)
	case .Multi_Pointer:
		payload := begin_variant(writer, image, "Type_Info_Multi_Pointer")
		return write_entry_pointer(writer, image, payload, "elem", descriptor.elem)
	case .Slice:
		payload := begin_variant(writer, image, "Type_Info_Slice")
		supported = write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		write_element_size(writer, image, payload, descriptor.elem)
		return supported, nil
	case .Dynamic_Array:
		payload := begin_variant(writer, image, "Type_Info_Dynamic_Array")
		supported = write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		write_element_size(writer, image, payload, descriptor.elem)
		return supported, nil
	case .Array:
		payload := begin_variant(writer, image, "Type_Info_Array")
		supported = write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		write_element_size(writer, image, payload, descriptor.elem)
		write_scalar_field(writer, image, payload, "count", u64(descriptor.count), 8)
		return supported, nil
	case .Enumerated_Array:
		payload := begin_variant(writer, image, "Type_Info_Enumerated_Array")
		supported = write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		index_supported := write_entry_pointer(writer, image, payload, "index", descriptor.index) or_return
		low, high := enum_bounds(writer, types.resolve_named(store, descriptor.index))
		write_element_size(writer, image, payload, descriptor.elem)
		write_scalar_field(writer, image, payload, "count", u64(descriptor.count), 8)
		write_scalar_field(writer, image, payload, "min_value", u64(low), 8)
		write_scalar_field(writer, image, payload, "max_value", u64(high), 8)
		return supported && index_supported, nil
	case .Map:
		payload := begin_variant(writer, image, "Type_Info_Map")
		key := write_entry_pointer(writer, image, payload, "key", descriptor.index) or_return
		value := write_entry_pointer(writer, image, payload, "value", descriptor.elem) or_return
		info := write_map_info_pointer(writer, image, payload, entry.type) or_return
		return key && value && info, nil
	case .Bit_Set:
		payload := begin_variant(writer, image, "Type_Info_Bit_Set")
		elem := write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		underlying := write_entry_pointer(writer, image, payload, "underlying", descriptor.backing) or_return
		write_scalar_field(writer, image, payload, "explicit_underlying", u64(descriptor.backing != types.TYPE_NONE), 1)
		write_scalar_field(writer, image, payload, "lower", u64(descriptor.lower_bound), 8)
		write_scalar_field(writer, image, payload, "upper", u64(descriptor.upper_bound), 8)
		return elem && underlying, nil
	case .Enum:
		payload := begin_variant(writer, image, "Type_Info_Enum")
		base := write_entry_pointer(writer, image, payload, "base", descriptor.backing) or_return
		members := enum_members_of(writer, entry.type)
		names := make([]string, len(members), writer.allocator) or_return
		values := make([]u64, len(members), writer.allocator) or_return
		for member, position in members {
			names[position] = member.name
			values[position] = u64(member.value)
		}
		names_array := string_array(writer, names) or_return
		values_array := scalar_array(writer, values, 8) or_return
		set_slice_field(writer, image, payload, "names", names_array, len(members)) or_return
		set_slice_field(writer, image, payload, "values", values_array, len(members)) or_return
		return base, nil
	case .Procedure:
		payload := begin_variant(writer, image, "Type_Info_Procedure")
		params, params_supported := parameters_global(writer, descriptor.params, descriptor.param_names) or_return
		results, results_supported := parameters_global(writer, descriptor.results, descriptor.result_names) or_return
		set_pointer_field(writer, image, payload, "params", params) or_return
		set_pointer_field(writer, image, payload, "results", results) or_return
		write_scalar_field(writer, image, payload, "variadic", u64(descriptor.variadic), 1)
		write_scalar_field(writer, image, payload, "convention", runtime_convention(descriptor.convention), 1)
		return params_supported && results_supported, nil
	case .Struct:
		return write_struct_variant(writer, image, entry, descriptor)
	case .Union:
		return write_union_variant(writer, image, entry, descriptor)
	case .Simd_Vector:
		payload := begin_variant(writer, image, "Type_Info_Simd_Vector")
		supported = write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		write_element_size(writer, image, payload, descriptor.elem)
		write_scalar_field(writer, image, payload, "count", u64(descriptor.count), 8)
		return supported, nil
	case .Matrix:
		payload := begin_variant(writer, image, "Type_Info_Matrix")
		supported = write_entry_pointer(writer, image, payload, "elem", descriptor.elem) or_return
		write_element_size(writer, image, payload, descriptor.elem)
		stride := descriptor.count
		if descriptor.row_major { stride = descriptor.upper_bound }
		write_scalar_field(writer, image, payload, "elem_stride", u64(stride), 8)
		write_scalar_field(writer, image, payload, "row_count", u64(descriptor.count), 8)
		write_scalar_field(writer, image, payload, "column_count", u64(descriptor.upper_bound), 8)
		write_scalar_field(writer, image, payload, "layout", u64(descriptor.row_major), 1)
		return supported, nil
	case .Bit_Field:
		return write_bit_field_variant(writer, image, entry, descriptor)
	}
	return false, nil
}

@(private)
write_bit_field_variant :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	entry: check.Type_Info_Entry,
	descriptor: types.Type,
) -> (
	supported: bool,
	err: runtime.Allocator_Error,
) {
	payload := begin_variant(writer, image, "Type_Info_Bit_Field")
	supported = write_entry_pointer(writer, image, payload, "backing_type", descriptor.backing) or_return
	targets := make([]int, len(descriptor.fields), writer.allocator) or_return
	names := make([]string, len(descriptor.fields), writer.allocator) or_return
	sizes := make([]u64, len(descriptor.fields), writer.allocator) or_return
	offsets := make([]u64, len(descriptor.fields), writer.allocator) or_return
	for field, position in descriptor.fields {
		target, found := entry_global(writer, field.type)
		if !found { return false, nil }
		targets[position] = target
		names[position] = field.name
		offset, size := types.bit_field_slot(writer.store, entry.type, position)
		sizes[position] = u64(size)
		offsets[position] = u64(offset)
	}
	count := len(descriptor.fields)
	names_array := string_array(writer, names) or_return
	types_array := pointer_array(writer, targets) or_return
	sizes_array := scalar_array(writer, sizes, 8) or_return
	offsets_array := scalar_array(writer, offsets, 8) or_return
	tags_array := string_array(writer, make([]string, count, writer.allocator) or_return) or_return
	set_slice_field(writer, image, payload, "names", names_array, count) or_return
	set_slice_field(writer, image, payload, "types", types_array, count) or_return
	set_slice_field(writer, image, payload, "bit_sizes", sizes_array, count) or_return
	set_slice_field(writer, image, payload, "bit_offsets", offsets_array, count) or_return
	set_slice_field(writer, image, payload, "tags", tags_array, count) or_return
	write_scalar_field(writer, image, payload, "field_count", u64(count), 8)
	return supported, nil
}

@(private)
write_struct_variant :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	entry: check.Type_Info_Entry,
	descriptor: types.Type,
) -> (
	supported: bool,
	err: runtime.Allocator_Error,
) {
	payload := begin_variant(writer, image, "Type_Info_Struct")
	fields := descriptor.fields
	targets := make([]int, len(fields), writer.allocator) or_return
	names := make([]string, len(fields), writer.allocator) or_return
	offsets := make([]u64, len(fields), writer.allocator) or_return
	usings := make([]u64, len(fields), writer.allocator) or_return
	tags := make([]string, len(fields), writer.allocator) or_return
	for field, position in fields {
		target, found := entry_global(writer, field.type)
		if !found { return false, nil }
		offset, offset_error := types.field_offset(writer.store, entry.type, position)
		if offset_error != .None { return false, nil }
		targets[position] = target
		names[position] = field.name
		offsets[position] = u64(offset)
		tags[position] = field.tag
	}
	count := len(fields)
	types_array := pointer_array(writer, targets) or_return
	names_array := string_array(writer, names) or_return
	offsets_array := scalar_array(writer, offsets, 8) or_return
	usings_array := scalar_array(writer, usings, 1) or_return
	tags_array := string_array(writer, tags) or_return
	set_pointer_field(writer, image, payload, "types", array_target(types_array, count)) or_return
	set_pointer_field(writer, image, payload, "names", array_target(names_array, count)) or_return
	set_pointer_field(writer, image, payload, "offsets", array_target(offsets_array, count)) or_return
	set_pointer_field(writer, image, payload, "usings", array_target(usings_array, count)) or_return
	set_pointer_field(writer, image, payload, "tags", array_target(tags_array, count)) or_return
	write_scalar_field(writer, image, payload, "field_count", u64(count), 4)
	flags: u64
	if descriptor.packed { flags |= 1 << STRUCT_FLAG_PACKED }
	if descriptor.raw_union { flags |= 1 << STRUCT_FLAG_RAW_UNION }
	if descriptor.custom_align != 0 { flags |= 1 << STRUCT_FLAG_ALIGN }
	write_scalar_field(writer, image, payload, "flags", flags, 1)
	if descriptor.soa != .None {
		write_scalar_field(writer, image, payload, "soa_kind", u64(descriptor.soa), 1)
		write_scalar_field(writer, image, payload, "soa_len", u64(descriptor.count), 4)
		return write_entry_pointer(writer, image, payload, "soa_base_type", descriptor.soa_elem)
	}
	return true, nil
}

@(private)
write_union_variant :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	entry: check.Type_Info_Entry,
	descriptor: types.Type,
) -> (
	supported: bool,
	err: runtime.Allocator_Error,
) {
	payload := begin_variant(writer, image, "Type_Info_Union")
	targets := make([]int, len(descriptor.variants), writer.allocator) or_return
	for variant, position in descriptor.variants {
		target, found := entry_global(writer, variant)
		if !found { return false, nil }
		targets[position] = target
	}
	layout, layout_error := types.union_layout(writer.store, entry.type)
	if layout_error != .None { return false, nil }
	tag_type := check.union_tag_type(writer.store, entry.type)
	tag_offset := i64(0)
	if layout.tag_size != 0 {
		tag_offset = layout.variant_block_size
	}
	tag, tag_found := entry_global(writer, tag_type)
	if !tag_found { return false, nil }
	variants_array := pointer_array(writer, targets) or_return
	set_slice_field(writer, image, payload, "variants", variants_array, len(targets)) or_return
	write_scalar_field(writer, image, payload, "tag_offset", u64(tag_offset), 8)
	set_pointer_field(writer, image, payload, "tag_type", tag) or_return
	write_scalar_field(writer, image, payload, "custom_align", u64(descriptor.custom_align != 0), 1)
	write_scalar_field(writer, image, payload, "no_nil", u64(descriptor.union_form == .No_Nil), 1)
	write_scalar_field(writer, image, payload, "shared_nil", u64(descriptor.union_form == .Shared_Nil), 1)
	return true, nil
}

// Writes the variant tag and returns the payload type of the variant with the given name; payload fields follow it.
@(private)
begin_variant :: proc(writer: ^Type_Info_Writer, image: ^Type_Info_Image, name: string) -> types.Type_Id {
	index, payload := variant_of(writer.store, writer.union_type, name)
	write_scalar(image.bytes, writer.union_offset + writer.variant_block, u64(index + 1), writer.tag_size)
	image.base = writer.union_offset
	return payload
}

@(private)
variant_of :: proc(store: ^types.Store, union_type: types.Type_Id, name: string) -> (index: int, payload: types.Type_Id) {
	for variant, position in types.get(store, union_type).variants {
		if strings.has_suffix(types.get(store, variant).name, name) { return position, variant }
	}
	panic("runtime Type_Info lacks a variant the lowering writes")
}

@(private)
field_location :: proc(store: ^types.Store, struct_type: types.Type_Id, name: string) -> (offset: i64, type: types.Type_Id) {
	struct_id := types.resolve_named(store, struct_type)
	for field, index in types.get(store, struct_id).fields {
		if field.name == name {
			offset, _ = types.field_offset(store, struct_id, index)
			return offset, field.type
		}
	}
	panic("runtime Type_Info lacks a field the lowering writes")
}

@(private)
write_scalar :: proc(bytes: []byte, offset: i64, value: u64, width: i64) {
	for index in 0 ..< width {
		bytes[offset + index] = byte(value >> uint(8 * index))
	}
}

@(private)
make_image :: proc(writer: ^Type_Info_Writer, struct_type: types.Type_Id) -> (image: Type_Info_Image, err: runtime.Allocator_Error) {
	size, _, _ := types.layout(writer.store, struct_type)
	image.bytes = make([]byte, size, writer.allocator) or_return
	image.relocs = make([dynamic]ir.Data_Reloc, writer.allocator) or_return
	return image, nil
}

// Appends the image as a global and returns its index. A finished image is never written again, so one with the same
// alignment, bytes and relocations shares the global already appended: type-info arrays repeat the same element
// tables and names for every type that mentions them.
@(private)
add_image :: proc(writer: ^Type_Info_Writer, image: Type_Info_Image, align: u32) -> (index: int, err: runtime.Allocator_Error) {
	key := image_key(writer, image, align) or_return
	if existing, found := writer.images[key]; found { return existing, nil }
	name := generated_global_name(writer, "data", u64(writer.image_count))
	writer.image_count += 1
	append(
		&writer.module.globals,
		ir.Global{name = name, size = u32(len(image.bytes)), align = align, bytes = image.bytes, relocs = image.relocs[:], anonymous = true},
	) or_return
	index = len(writer.module.globals) - 1
	writer.images[key] = index
	return index, nil
}

// The alignment, bytes and relocation list of an image as one map key.
@(private)
image_key :: proc(writer: ^Type_Info_Writer, image: Type_Info_Image, align: u32) -> (key: string, err: runtime.Allocator_Error) {
	bytes := make([dynamic]byte, 0, len(image.bytes) + 32 * len(image.relocs) + 16, writer.allocator) or_return
	append_key_integer(&bytes, u64(align)) or_return
	append_key_integer(&bytes, u64(len(image.bytes))) or_return
	append(&bytes, ..image.bytes) or_return
	append_key_integer(&bytes, u64(len(image.relocs))) or_return
	for reloc in image.relocs {
		space := reloc.target.space
		append_key_integer(&bytes, u64(space)) or_return
		append_key_integer(&bytes, u64(reloc.offset)) or_return
		append_key_integer(&bytes, u64(reloc.target.index)) or_return
		append_key_integer(&bytes, u64(reloc.addend)) or_return
	}
	return string(bytes[:]), nil
}

@(private)
append_key_integer :: proc(bytes: ^[dynamic]byte, value: u64) -> runtime.Allocator_Error {
	value := value
	_, err := append(bytes, ..mem.ptr_to_bytes(&value))
	return err
}

@(private)
module_symbol_names :: proc(module: ^ir.Module, allocator: runtime.Allocator) -> (names: map[string]struct{}) {
	names = make(map[string]struct{}, allocator)
	for global in module.globals { names[global.name] = {} }
	for function in module.functions { names[function.name] = {} }
	for external in module.externs { names[external.name] = {} }
	return names
}

// Unique across the module's globals, functions and externs: a numeric suffix resolves a clash.
@(private)
generated_global_name :: proc(writer: ^Type_Info_Writer, role: string, ordinal: u64) -> string {
	base := fmt.aprintf("__odinc_internal_type_info_%s_%d", role, ordinal, allocator = writer.allocator)
	candidate := base
	for suffix := 1; (candidate in writer.names_in_use); suffix += 1 {
		candidate = fmt.aprintf("%s_%d", base, suffix, allocator = writer.allocator)
	}
	writer.names_in_use[candidate] = {}
	return candidate
}

// Global index of the runtime entry of `type`; -1 for TYPE_NONE (nil). False when the type has no entry.
@(private)
entry_global :: proc(writer: ^Type_Info_Writer, type: types.Type_Id) -> (index: int, found: bool) {
	if type == types.TYPE_NONE { return -1, true }
	representative := type
	if int(type) < len(writer.representatives) { representative = writer.representatives[type] }
	for entry, position in writer.entries {
		if entry.type == representative { return int(writer.first) + position, true }
	}
	return -1, false
}

// Nil for an empty slice or array, so that its data pointer is never read.
@(private)
array_target :: proc(index: int, count: int) -> int {
	if count == 0 { return -1 }
	return index
}

@(private)
pointer_array :: proc(writer: ^Type_Info_Writer, targets: []int) -> (index: int, err: runtime.Allocator_Error) {
	image: Type_Info_Image
	image.bytes = make([]byte, 8 * len(targets), writer.allocator) or_return
	image.relocs = make([dynamic]ir.Data_Reloc, writer.allocator) or_return
	for target, position in targets {
		if target >= 0 {
			append(&image.relocs, ir.Data_Reloc{offset = u32(8 * position), target = {.Global, u32(target)}}) or_return
		}
	}
	return add_image(writer, image, 8)
}

// The text bytes of a string as a global; -1 for the empty string, whose data pointer stays nil.
@(private)
string_global :: proc(writer: ^Type_Info_Writer, text: string) -> (index: int, err: runtime.Allocator_Error) {
	if len(text) == 0 { return -1, nil }
	image: Type_Info_Image
	image.bytes = make([]byte, len(text), writer.allocator) or_return
	copy(image.bytes, text)
	return add_image(writer, image, 1)
}

@(private)
string_array :: proc(writer: ^Type_Info_Writer, texts: []string) -> (index: int, err: runtime.Allocator_Error) {
	image: Type_Info_Image
	image.bytes = make([]byte, 16 * len(texts), writer.allocator) or_return
	image.relocs = make([dynamic]ir.Data_Reloc, writer.allocator) or_return
	for text, position in texts {
		write_scalar(image.bytes, i64(16 * position + 8), u64(len(text)), 8)
		target := string_global(writer, text) or_return
		if target >= 0 {
			append(&image.relocs, ir.Data_Reloc{offset = u32(16 * position), target = {.Global, u32(target)}}) or_return
		}
	}
	return add_image(writer, image, 8)
}

@(private)
scalar_array :: proc(writer: ^Type_Info_Writer, values: []u64, width: i64) -> (index: int, err: runtime.Allocator_Error) {
	image: Type_Info_Image
	image.bytes = make([]byte, int(width) * len(values), writer.allocator) or_return
	for value, position in values {
		write_scalar(image.bytes, i64(position) * width, value, width)
	}
	return add_image(writer, image, 8)
}

// The `Type_Info_Parameters` of a procedure's parameters or results; -1 when there are none.
@(private)
parameters_global :: proc(writer: ^Type_Info_Writer, list: []types.Type_Id, names: []string) -> (target: int, supported: bool, err: runtime.Allocator_Error) {
	if len(list) == 0 { return -1, true, nil }
	if writer.parameters_type == types.TYPE_NONE { return -1, false, nil }
	targets := make([]int, len(list), writer.allocator) or_return
	for member, position in list {
		index, found := entry_global(writer, member)
		if !found { return -1, false, nil }
		targets[position] = index
	}
	image := make_image(writer, writer.info_type) or_return
	payload := begin_variant(writer, &image, "Type_Info_Parameters")
	types_array := pointer_array(writer, targets) or_return
	set_slice_field(writer, &image, payload, "types", types_array, len(list)) or_return
	parameter_names := names
	if len(parameter_names) == 0 { parameter_names = make([]string, len(list), writer.allocator) or_return }
	names_array := string_array(writer, parameter_names) or_return
	set_slice_field(writer, &image, payload, "names", names_array, len(list)) or_return
	index := add_image(writer, image, 8) or_return
	return index, true, nil
}

@(private)
runtime_convention :: proc(convention: types.Calling_Convention) -> u64 {
	switch convention {
	case .Odin:
		return 1
	case .Contextless:
		return 2
	case .C:
		return 3
	case .Stdcall:
		return 4
	case .Fastcall:
		return 5
	case .Win64:
		return 9
	case .SysV:
		return 10
	case .Preserve_None:
		return 11
	case .Preserve_Most:
		return 12
	case .Preserve_All:
		return 13
	case .Inline_Asm:
		return 0
	}
	return 0
}

@(private)
enum_members_of :: proc(writer: ^Type_Info_Writer, enum_type: types.Type_Id) -> []check.Enum_Member {
	for table in writer.enum_members {
		if table.type == enum_type { return table.members }
	}
	return nil
}

@(private)
enum_bounds :: proc(writer: ^Type_Info_Writer, enum_type: types.Type_Id) -> (low: i128, high: i128) {
	for member, position in enum_members_of(writer, enum_type) {
		if position == 0 || member.value < low { low = member.value }
		if position == 0 || member.value > high { high = member.value }
	}
	return low, high
}

@(private)
write_element_size :: proc(writer: ^Type_Info_Writer, image: ^Type_Info_Image, payload: types.Type_Id, element: types.Type_Id) {
	size, _, _ := types.layout(writer.store, element)
	write_scalar_field(writer, image, payload, "elem_size", u64(size), 8)
}

// Offset of a field in the image: the current struct's base plus the field's offset in its struct.
@(private)
field_position :: proc(image: ^Type_Info_Image, store: ^types.Store, struct_type: types.Type_Id, name: string) -> i64 {
	offset, _ := field_location(store, struct_type, name)
	return image.base + offset
}

@(private)
write_scalar_field :: proc(writer: ^Type_Info_Writer, image: ^Type_Info_Image, struct_type: types.Type_Id, name: string, value: u64, width: i64) {
	write_scalar(image.bytes, field_position(image, writer.store, struct_type, name), value, width)
}

@(private)
set_pointer_field :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	struct_type: types.Type_Id,
	name: string,
	target: int,
) -> runtime.Allocator_Error {
	if target < 0 { return nil }
	position := field_position(image, writer.store, struct_type, name)
	append(&image.relocs, ir.Data_Reloc{offset = u32(position), target = {.Global, u32(target)}}) or_return
	return nil
}

// A slice header: the data pointer, then the length eight bytes later.
@(private)
set_slice_field :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	struct_type: types.Type_Id,
	name: string,
	target: int,
	count: int,
) -> runtime.Allocator_Error {
	position := field_position(image, writer.store, struct_type, name)
	write_scalar(image.bytes, position + 8, u64(count), 8)
	if count == 0 { return nil }
	return set_pointer_field(writer, image, struct_type, name, target)
}

@(private)
set_string_field :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	struct_type: types.Type_Id,
	name: string,
	text: string,
) -> runtime.Allocator_Error {
	target := string_global(writer, text) or_return
	return set_slice_field(writer, image, struct_type, name, target, len(text))
}

// Nil for TYPE_NONE; false when the target has no entry.
@(private)
write_entry_pointer :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	struct_type: types.Type_Id,
	name: string,
	target: types.Type_Id,
) -> (
	bool,
	runtime.Allocator_Error,
) {
	index, found := entry_global(writer, target)
	if !found { return false, nil }
	return true, set_pointer_field(writer, image, struct_type, name, index)
}

// The Map_Info global for a map type. Stays nil when no global exists (a key
// the generator cannot hash); the runtime prints such a map as empty.
@(private)
write_map_info_pointer :: proc(
	writer: ^Type_Info_Writer,
	image: ^Type_Info_Image,
	struct_type: types.Type_Id,
	type: types.Type_Id,
) -> (
	bool,
	runtime.Allocator_Error,
) {
	map_type := types.resolve_named(writer.store, type)
	for entry in writer.map_info {
		if entry.type != map_type { continue }
		if int(entry.symbol) <= 0 || int(entry.symbol) >= len(writer.symbols) { return true, nil }
		symbol := writer.symbols[entry.symbol]
		if symbol.space != .Global { return true, nil }
		return true, set_pointer_field(writer, image, struct_type, "map_info", int(symbol.index))
	}
	return true, nil
}

// The typeid value of a `typeid_of` plan: its entry in the runtime type info holds the encoded id.
@(private)
lower_typeid :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Typeid_Plan) -> ir.Node_Id {
	return lower_runtime_typeid(state, node, plan.type)
}

@(private)
lower_type_info_of :: proc(state: ^Procedure_State, node: syntax.Node_Index, plan: check.Type_Info_Plan) -> ir.Node_Id {
	requirements := check.runtime_requirements(state.job.program)
	type := plan.type
	if int(type) < len(requirements.type_info_representatives) { type = requirements.type_info_representatives[type] }
	for entry in requirements.type_info {
		if entry.type != type { continue }
		symbol := check.entity_symbol(state.job.program, plan.table)
		if symbol == 0 { return lower_fail(state, node, .Runtime_Type_Info) }
		address := ir.symbol_addr(state.job.function, state.job.symbols[symbol])
		data := lower_load_word(state, address, .Ptr)
		return lower_load_word(state, ir.ptr_offset(state.job.function, data, i64(entry.slot) * 8), .Ptr)
	}
	return lower_fail(state, node, .Runtime_Type_Info)
}

@(private)
lower_runtime_typeid :: proc(state: ^Procedure_State, node: syntax.Node_Index, type: types.Type_Id) -> ir.Node_Id {
	requirements := check.runtime_requirements(state.job.program)
	representative := type
	if int(type) < len(requirements.type_info_representatives) { representative = requirements.type_info_representatives[type] }
	for entry in requirements.type_info {
		if entry.type == representative {
			return ir.const_int(state.job.function, .I64, i64(entry.runtime_id))
		}
	}
	return lower_fail(state, node, .Expression)
}
