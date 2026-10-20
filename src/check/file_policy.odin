package check

import "core:strings"
import "oc:syntax"

@(private = "file")
append_file_feature :: proc(features: ^[dynamic]string, feature: string) -> Binding_Error {
	for previous in features { if previous == feature { return nil } }
	append(features, feature) or_return
	return nil
}

@(private = "package")
collect_file_features :: proc(collection: ^Collection, file: ^File, root: syntax.File) -> (err: Binding_Error) {
	features: [dynamic]string
	features.allocator = collection.allocator
	defer if err != nil || len(features) == 0 { delete(features) }
	for tag in syntax.node_list(file.ast, root.tags) {
		span := file.ast.nodes[tag]
		source := file.source[span.start:span.end]
		if !strings.has_prefix(string(source), "#+feature ") { continue }
		source = source[len("#+feature "):]
		tokenizer := syntax.init(source, nil, nil)
		if len(features) == 0 { append(&features, ..file.policy.features) or_return }
		start, end: u32
		for token := syntax.next(&tokenizer);; token = syntax.next(&tokenizer) {
			if token.kind == .EOF || token.kind == .Semicolon {
				if end > start { append_file_feature(&features, string(source[start:end])) or_return }
				break
			}
			if token.start != end {
				if end > start { append_file_feature(&features, string(source[start:end])) or_return }
				start = token.start
			}
			end = token.end
		}
	}
	if len(features) == 0 { return nil }
	append(&collection.file_features, features[:]) or_return
	file.policy.features = features[:]
	return nil
}
