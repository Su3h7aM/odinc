package amd64

import "oc:ir"

// Local-exec TLS address: the thread pointer in fs:0 plus the link-time TPOFF64 of the symbol.
@(private)
select_thread_local_address :: proc(selector: ^Selector, node: ir.Node_Id, destination: Vreg) -> Select_Status {
	output, block := selector.output, selector.block
	symbol := selector.input.nodes.data[node].symbol
	thread_pointer := new_vreg(output, .Int) or_return
	offset := new_vreg(output, .Int) or_return
	emit(output, block, .MOV, 8, thread_pointer, Memory_Ref{segment_fs = true}) or_return
	emit(output, block, .MOVABS, 8, offset, Thread_Pointer_Offset{symbol = symbol}) or_return
	return emit(output, block, .ADD, 8, destination, thread_pointer, offset)
}
