package values

@(private = "file")
local_value := 31

@(private = "file")
get_value :: proc() -> int { return local_value }

second :: proc() -> int { return get_value() }
