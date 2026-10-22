#!/usr/bin/env bash
# Shared helpers for the task scripts. Not executable on purpose: mise only
# discovers executable files as tasks.

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ODIN="${ODIN_BIN:?ODIN_BIN must name the bootstrap odin binary}"
[[ -x "$ODIN" ]] || { printf 'error: %s is not executable\n' "$ODIN" >&2; exit 1; }
export ODIN_ROOT="$PROJECT_ROOT"

COLLECTION="-collection:oc=$PROJECT_ROOT/src"

project_packages() {
	local dir
	for dir in "$PROJECT_ROOT"/src/*/; do
		if [[ -n "$(compgen -G "${dir}*.odin")" ]]; then
			basename "$dir"
		fi
	done
}

package_has_tests() {
	[[ -n "$(compgen -G "$PROJECT_ROOT/src/$1/*_test.odin")" ]]
}

owned_sources() {
	find "$PROJECT_ROOT/src" -name '*.odin' | sort
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

step() { printf '\n==> %s\n' "$*"; }

# Serializes binary-producing tasks: they share build/ outputs. Waits for the holder; the lock lives until the process exits.
acquire_binary_lock() {
	mkdir -p "$PROJECT_ROOT/build"
	exec 9>"$PROJECT_ROOT/build/.lock"
	flock -x 9
}
