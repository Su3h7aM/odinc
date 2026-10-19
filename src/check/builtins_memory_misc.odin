package check

@(private)
memory_misc_shape :: proc(kind: Builtin_Kind) -> Intrinsic_Shape {
	#partial switch kind {
	case .Cpu_Relax, .Debug_Trap:
		return .Fence
	case .Mem_Zero, .Mem_Zero_Volatile:
		return .Bytes_Zero
	case .Non_Temporal_Load:
		return .Load
	case .Non_Temporal_Store:
		return .Store
	}
	return .None
}
