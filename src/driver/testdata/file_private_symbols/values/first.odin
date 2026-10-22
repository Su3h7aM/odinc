package values

@(private = "file")
local_value := 11

@(private = "file")
get_value :: proc() -> int { return local_value }

first :: proc() -> int { return get_value() }
