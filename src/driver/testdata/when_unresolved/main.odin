package when_unresolved

import "./pkg"

main :: proc() {
	_ = pkg.FROM_LATER
}
