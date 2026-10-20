package lib

seen: int

@(init)
lib_init :: proc "contextless" () { seen = 3 }
