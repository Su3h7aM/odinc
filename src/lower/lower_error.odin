package lower

import "oc:check"
import "oc:ir"
import "oc:types"

Lower_Code :: enum u8 {
	None,
	Unsupported,
	Verification,
	Abi,
}

Lower_Feature :: enum u8 {
	None,
	Body,
	Generated_Body,
	Parameter,
	Result,
	Global_Initializer,
	Runtime_Type_Info,
	Startup,
	Signature,
	Expression,
	Operator,
	Constant,
	Conversion,
	Place,
	Local,
	Bounds,
	Control,
	Defer,
	Range,
	Switch,
	Call,
	Call_Argument,
	Context,
	Builtin,
	Syscall,
	Map_Info_Hasher,
	Unchecked_Expression,
}

Lower_Error :: struct {
	code:           Lower_Code,
	feature:        Lower_Feature,
	entity:         check.Entity_Id,
	node:           check.Node_Ref,
	source:         check.Source_Span,
	function_index: u32,
	verify_code:    ir.Verify_Code,
	abi_error:      types.Plan_Error,
}
