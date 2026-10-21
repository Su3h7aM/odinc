package check

// Opt-in language features come from `#+feature` file tags before the package clause
// (collect_file_features). Like upstream's check_feature_flags, they apply per file, never per package.
dynamic_literals_enabled :: proc(file: ^File) -> bool {
	for feature in file.policy.features {
		if feature == "dynamic-literals" { return true }
	}
	return false
}
