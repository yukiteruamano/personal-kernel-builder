#!/bin/bash
# Bash completion tests: feed command lines to the completion function and check COMPREPLY.
# Usage: tests/completion.sh
set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../personal-kernel-builder.bash-completion
source "$TEST_DIR/../personal-kernel-builder.bash-completion"
PASSED=0
FAILED=0

# completes LINE EXPECTED: completing the last word of LINE must offer exactly EXPECTED
completes() {
	local line=$1 expected=$2 got
	read -ra COMP_WORDS <<<"$line"
	# A trailing space means the cursor is on a new, empty word
	[[ $line != *" " ]] || COMP_WORDS+=("")
	COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
	COMPREPLY=()
	_personal_kernel_builder
	got="${COMPREPLY[*]}"
	if [[ $got == "$expected" ]]; then
		PASSED=$((PASSED + 1))
	else
		FAILED=$((FAILED + 1))
		echo "FAIL: '$line' offered [$got], expected [$expected]" >&2
	fi
}

completes "personal-kernel-builder con" "config"
completes "personal-kernel-builder --dry-run inst" "install"
completes "personal-kernel-builder -" "--dry-run --help"
completes "personal-kernel-builder config " "olddefconfig menuconfig"
completes "personal-kernel-builder config olddefconfig " ""
completes "personal-kernel-builder backup " "list"
completes "personal-kernel-builder install --" "--initrd --no-initrd --fix-grub-uuid --dry-run"
completes "personal-kernel-builder build --" "--jobs"
completes "personal-kernel-builder build --jobs " ""
completes "personal-kernel-builder init --name volfread --c" "--config"
completes "personal-kernel-builder diff " "default running"
completes "personal-kernel-builder uninstall --k" "--keep"

echo "passed: $PASSED, failed: $FAILED"
((FAILED == 0))
