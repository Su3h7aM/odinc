# Checker publication

The checker keeps its pools in `Expression_Checker` (views, plans, symbols, entity symbols, procedures, diagnostics) and the scope store, constant pool, and type store it borrows. Lower reads only the `Checked_Program` view of them.

Publication is a copy of slice headers, not of data. Growing any pool after publication can reallocate it and leave a previously exported slice pointing at old memory. So publication runs after the last checking phase: once every reachable declaration is resolved and no further pool growth happens.

The driver follows this order:

1. Collect every file of every package, then bind imports.
2. Resolve the declarations of the main package. Library declarations are resolved only when referenced.
3. Confirm the diagnostics lists are empty.
4. Set `Checked_Program.files` from the parsed files.
5. Call `expression_checker_publish_procedures`, which rebuilds the symbol and procedure tables from the final entity states and then calls `expression_checker_publish`.

Republish after any later phase that grows a pool: call the publish procedure again. Calling it again rebuilds the symbol and procedure tables from scratch, so earlier exported slices are replaced, not appended to.
