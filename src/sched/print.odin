package sched

import "core:io"
import "core:strconv"
import ir "oc:ir"

// Prints the layout order of `schedule`: one header per block, then its nodes in order.
print_schedule :: proc(w: io.Writer, fn: ^ir.Function, schedule: Schedule, options := ir.DEFAULT_PRINT_OPTIONS) -> io.Error {
	put(w, "func f") or_return
	put_int(w, i64(fn.id)) or_return
	put(w, " ") or_return
	put_quoted(w, fn.name) or_return
	put(w, " sched {\n") or_return
	for block in schedule.blocks {
		print_block(w, fn, schedule.cfg, block, options) or_return
	}
	put(w, "}\n") or_return
	return nil
}

@(private = "file")
print_block :: proc(w: io.Writer, fn: ^ir.Function, cfg: ir.Cfg, block: Block, options: ir.Print_Options) -> io.Error {
	put(w, "  block b") or_return
	put_int(w, i64(block.id)) or_return
	put(w, " head=") or_return
	put(w, options.value_prefix) or_return
	put_int(w, i64(block.head)) or_return
	put(w, " depth=") or_return
	put_int(w, i64(block.depth)) or_return
	put(w, " preds=") or_return
	print_block_list(w, ir.block_preds(cfg, block.id)) or_return
	put(w, " succs=") or_return
	print_block_list(w, ir.block_succs(cfg, block.id)) or_return
	if block.cold {
		put(w, " cold") or_return
	}
	put(w, "\n") or_return
	node_options := options
	node_options.indent = "    "
	for id in block.nodes {
		ir.print_node_line(w, fn, id, node_options) or_return
	}
	return nil
}

@(private = "file")
print_block_list :: proc(w: io.Writer, blocks: []ir.Block_Id) -> io.Error {
	put(w, "[") or_return
	for block, position in blocks {
		if position > 0 {
			put(w, ",") or_return
		}
		put(w, "b") or_return
		put_int(w, i64(block)) or_return
	}
	return put(w, "]")
}

@(private = "file")
put :: proc(w: io.Writer, text: string) -> io.Error {
	_, err := io.write_string(w, text)
	return err
}

@(private = "file")
put_int :: proc(w: io.Writer, value: i64) -> io.Error {
	buf: [24]byte
	return put(w, strconv.write_int(buf[:], value, 10))
}

@(private = "file")
put_quoted :: proc(w: io.Writer, text: string) -> io.Error {
	put(w, "\"") or_return
	put(w, text) or_return
	return put(w, "\"")
}
