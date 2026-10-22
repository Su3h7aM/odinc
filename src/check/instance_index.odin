package check

import "base:runtime"
import "core:mem"
import "oc:types"

// Generic instances bucketed by a hash of their definition and poly arguments. Each bucket lists its
// instances in creation order, which is entity order, so the first matching entry is the first match in entity order.
@(private = "package")
Instance_Index :: struct {
	buckets: map[u64][dynamic]Entity_Id,
}

// Only the kind of each poly type is hashed: identity implies equal kinds, and a kind never changes once a
// type id exists, even when a reserved nominal is completed. Matching still uses the full comparison.
@(private = "package")
instance_index_key :: proc(store: ^types.Store, definition: Entity_Id, poly_types: []types.Type_Id, poly_constants: []Const_Id) -> u64 {
	hash := u64(14695981039346656037)
	hash = instance_index_mix(hash, u64(definition))
	hash = instance_index_mix(hash, u64(len(poly_types)))
	for poly_type in poly_types {
		kind := u64(0) if poly_type == types.TYPE_NONE else u64(types.get(store, poly_type).kind)
		hash = instance_index_mix(hash, kind)
	}
	for constant in poly_constants { hash = instance_index_mix(hash, u64(constant)) }
	return hash
}

@(private = "file")
instance_index_mix :: proc(hash, value: u64) -> u64 {
	return (hash ~ value) * 1099511628211
}

@(private = "package")
instance_index_candidates :: proc(index: ^Instance_Index, key: u64) -> []Entity_Id {
	if index.buckets == nil { return nil }
	bucket, present := index.buckets[key]
	return bucket[:] if present else nil
}

@(private = "package")
instance_index_insert :: proc(index: ^Instance_Index, allocator: mem.Allocator, key: u64, instance: Entity_Id) -> runtime.Allocator_Error {
	if index.buckets == nil { index.buckets = make(map[u64][dynamic]Entity_Id, allocator) }
	_, bucket, _, entry_error := map_entry(&index.buckets, key)
	if entry_error != nil { return entry_error }
	if bucket.allocator.procedure == nil { bucket.allocator = allocator }
	append(bucket, instance) or_return
	return nil
}

@(private = "package")
instance_index_destroy :: proc(index: ^Instance_Index) {
	if index.buckets == nil { return }
	for _, bucket in index.buckets { delete(bucket) }
	delete(index.buckets)
	index^ = {}
}
