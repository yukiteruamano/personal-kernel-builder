#!/bin/bash
# Unit tests: run the library functions against a throwaway directory tree.
# Usage: tests/unit.sh
set -Eeuo pipefail

TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR=$TEST_DIR/../lib
export PROG=personal-kernel-builder
# shellcheck source=../lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=../lib/kconfig.sh
source "$LIB_DIR/kconfig.sh"
# shellcheck source=../lib/build.sh
source "$LIB_DIR/build.sh"
# shellcheck source=../lib/install.sh
source "$LIB_DIR/install.sh"
# shellcheck source=../lib/report.sh
source "$LIB_DIR/report.sh"
# Tests replace check_root_owned inside subshells, so shellcheck sees it as never called
# shellcheck disable=SC2329

SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
PASSED=0
FAILED=0

# ok DESCRIPTION CMD...: the command must succeed
ok() {
	local description=$1
	shift
	if ("$@") >"$SANDBOX/out" 2>&1; then
		PASSED=$((PASSED + 1))
	else
		FAILED=$((FAILED + 1))
		echo "FAIL (expected success): $description" >&2
		sed 's/^/    /' "$SANDBOX/out" >&2
	fi
}

# fails DESCRIPTION CMD...: the command must fail
fails() {
	local description=$1
	shift
	if ("$@") >"$SANDBOX/out" 2>&1; then
		FAILED=$((FAILED + 1))
		echo "FAIL (expected failure): $description" >&2
	else
		PASSED=$((PASSED + 1))
	fi
}

# equals EXPECTED ACTUAL: string equality for use with ok/fails
equals() {
	[[ $1 == "$2" ]] || {
		echo "expected [$1], got [$2]"
		return 1
	}
}

# Point every system path into the sandbox
ETC_DIR=$SANDBOX/etc/pkb
CONF_FILE=$ETC_DIR/pkb.conf
PERSONAL_CFG=$ETC_DIR/personal.config
BACKUP_DIR=$ETC_DIR/backups
STATE_DIR=$SANDBOX/state
GRUB_DEFAULTS=$SANDBOX/grub
BUILD_ROOT=$SANDBOX/tmp
mkdir -p "$ETC_DIR" "$BACKUP_DIR" "$STATE_DIR" "$BUILD_ROOT"
NAME=volfread

# --- settings ---------------------------------------------------------------
test_load_conf() {
	check_root_owned() { :; }
	printf '# comment\n\nNAME="volfread"\nJOBS=8\nVERIFY_MODULES=a b c\n' >"$CONF_FILE"
	load_conf
	equals "volfread 8 a b c" "$NAME $JOBS $VERIFY_MODULES"
}
ok "load_conf reads KEY=VALUE and strips quotes" test_load_conf

test_load_conf_unknown() {
	check_root_owned() { :; }
	printf 'PATH=/evil\n' >"$CONF_FILE"
	load_conf
}
fails "load_conf rejects unknown settings" test_load_conf_unknown

test_load_conf_code() {
	check_root_owned() { :; }
	# shellcheck disable=SC2016 # the command substitution must stay literal
	printf 'NAME=x\n$(touch %s/pwned)\n' "$SANDBOX" >"$CONF_FILE"
	load_conf
}
fails "load_conf rejects lines that are not KEY=VALUE" test_load_conf_code
ok "load_conf never executes the file" test ! -e "$SANDBOX/pwned"

test_conf_not_root() {
	echo NAME=x >"$CONF_FILE"
	load_conf
}
if [[ $EUID -ne 0 ]]; then
	fails "load_conf refuses a config not owned by root" test_conf_not_root
fi

ok "valid_name accepts volfread" valid_name volfread
fails "valid_name rejects path characters" valid_name ../x
fails "valid_name rejects uppercase and spaces" valid_name "Volf read"
ok "valid_release accepts 7.3.3-e14g2" valid_release 7.3.3-e14g2
fails "valid_release rejects slashes" valid_release 7.3/../../etc

test_validate_bad_jobs() {
	JOBS=0
	validate_settings
}
fails "validate_settings rejects --jobs 0" test_validate_bad_jobs

# --- kernel config helpers --------------------------------------------------
cat >"$SANDBOX/a.config" <<'EOF'
# Linux/x86 7.3.3 Kernel Configuration
CONFIG_LOCALVERSION="-e14g2"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_XFS_FS=y
CONFIG_AMD_PMC=m
CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"
CONFIG_CC_VERSION_TEXT="gcc 15"
EOF

test_localversion() {
	cp "$SANDBOX/a.config" "$SANDBOX/b.config"
	set_localversion "$SANDBOX/b.config"
	equals "-volfread" "$(config_value LOCALVERSION "$SANDBOX/b.config")"
}
ok "set_localversion writes -NAME" test_localversion

test_set_unset_option() {
	printf '# CONFIG_FOO is not set\n' >"$SANDBOX/c.config"
	set_config_str "$SANDBOX/c.config" FOO bar
	equals 'CONFIG_FOO="bar"' "$(cat "$SANDBOX/c.config")"
}
ok "set_config_str replaces 'is not set' lines" test_set_unset_option

test_critical_ok() {
	CRITICAL_OPTIONS="XFS_FS=y AMD_PMC"
	check_critical "$SANDBOX/a.config"
}
ok "check_critical accepts y and m" test_critical_ok

test_critical_builtin() {
	CRITICAL_OPTIONS="AMD_PMC=y"
	check_critical "$SANDBOX/a.config"
}
fails "check_critical requires =y when asked" test_critical_builtin

test_signing_all() {
	printf 'CONFIG_MODULE_SIG=y\nCONFIG_MODULE_SIG_ALL=y\n' >"$SANDBOX/s.config"
	check_signing "$SANDBOX/s.config"
}
ok "check_signing accepts MODULE_SIG with MODULE_SIG_ALL" test_signing_all

test_signing_missing_all() {
	printf 'CONFIG_MODULE_SIG=y\n# CONFIG_MODULE_SIG_ALL is not set\n' >"$SANDBOX/s.config"
	check_signing "$SANDBOX/s.config"
}
fails "check_signing rejects MODULE_SIG without MODULE_SIG_ALL" test_signing_missing_all

test_signing_off() {
	printf '# CONFIG_MODULE_SIG is not set\n' >"$SANDBOX/s.config"
	check_signing "$SANDBOX/s.config"
}
ok "check_signing ignores configs without MODULE_SIG" test_signing_off

test_config_rejects_bad_personal() {
	CRITICAL_OPTIONS="MODULE_SIG"
	printf '# CONFIG_MODULE_SIG is not set\n' >"$PERSONAL_CFG"
	prepare_tree() { echo "must not copy the sources"; exit 3; }
	ARGS=(olddefconfig)
	cmd_config
}
test_config_message() {
	local output
	output=$( (test_config_rejects_bad_personal) 2>&1 || true)
	[[ $output == *"critical options wrong in $PERSONAL_CFG: MODULE_SIG=unset"* ]] || {
		echo "$output"
		return 1
	}
}
fails "config olddefconfig stops before copying when personal.config lacks a critical option" \
	test_config_rejects_bad_personal
ok "config olddefconfig names personal.config in the error" test_config_message

test_critical_empty_warns() {
	CRITICAL_OPTIONS=""
	local output
	output=$(check_critical "$SANDBOX/a.config" 2>&1)
	[[ $output == *"CRITICAL_OPTIONS is empty"* ]]
}
ok "check_critical warns when CRITICAL_OPTIONS is empty" test_critical_empty_warns

test_create_conf_from_template() {
	DRY_RUN=no
	CONF_FILE=$SANDBOX/new-etc/pkb.conf
	mkdir -p "$SANDBOX/new-etc"
	printf 'CRITICAL_OPTIONS=MODULE_SIG\n' >"$CONF_FILE.new"
	# The real install needs root for -o/-g; create_conf calls this stand-in through run
	# shellcheck disable=SC2329
	install() { cp -- "${@: -2:1}" "${@: -1}"; }
	create_conf
	grep -q '^CRITICAL_OPTIONS=MODULE_SIG$' "$CONF_FILE"
}
ok "create_conf starts from the package's .conf.new" test_create_conf_from_template

test_changes_ignored() {
	sed -e 's/e14g2/volfread/' -e 's/certs.*pem/\/etc\/key.pem/' -e 's/gcc 15/gcc 16/' \
		"$SANDBOX/a.config" >"$SANDBOX/d.config"
	equals "" "$(config_changes "$SANDBOX/a.config" "$SANDBOX/d.config")"
}
ok "config_changes ignores LOCALVERSION, MODULE_SIG_KEY and toolchain symbols" test_changes_ignored

test_changes_found() {
	sed 's/CONFIG_AMD_PMC=m/# CONFIG_AMD_PMC is not set/' "$SANDBOX/a.config" >"$SANDBOX/e.config"
	equals "CONFIG_AMD_PMC: m -> n" "$(config_changes "$SANDBOX/a.config" "$SANDBOX/e.config")"
}
ok "config_changes reports disabled options as n" test_changes_found

test_changes_gone() {
	printf 'CONFIG_PROC_SYSCTL=y\n# CONFIG_OLD_THING is not set\nCONFIG_BINDGEN_VERSION_TEXT="bindgen 0.73.2"\n' \
		>"$SANDBOX/f.config"
	printf 'CONFIG_SYSCTL=y\n' >"$SANDBOX/g.config"
	equals "CONFIG_PROC_SYSCTL: y -> (gone)" "$(config_changes "$SANDBOX/f.config" "$SANDBOX/g.config")"
}
ok "config_changes marks vanished symbols as gone and skips bindgen and disabled ones" test_changes_gone

# --- backups ----------------------------------------------------------------
test_first_backup() {
	BACKUP_DIR=$SANDBOX/empty-backups
	mkdir -p "$BACKUP_DIR"
	echo "CONFIG_N=0" >"$PERSONAL_CFG"
	backup_personal
	equals 1 "$(list_backups | wc -l)"
}
ok "backup_personal works when there is no backup yet" test_first_backup

test_grub_missing_defaults() {
	GRUB_DEFAULTS=$SANDBOX/no-such-grub
	equals "" "$(grub_top_level_release)"
}
ok "grub_top_level_release copes with a missing /etc/default/grub" test_grub_missing_defaults

test_backup_rotation() {
	KEEP_BACKUPS=7
	local i
	for i in 1 2 3 4 5 6 7 8 9; do
		echo "CONFIG_N=$i" >"$BACKUP_DIR/personal-2026010$i-120000.config"
	done
	echo "CONFIG_N=10" >"$PERSONAL_CFG"
	backup_personal
	equals 7 "$(list_backups | wc -l)"
}
ok "backup_personal keeps at most KEEP_BACKUPS copies" test_backup_rotation

test_backup_skip_identical() {
	local before
	before=$(list_backups | wc -l)
	backup_personal
	equals "$before" "$(list_backups | wc -l)"
}
ok "backup_personal skips a copy identical to the newest" test_backup_skip_identical

ok "find_backup finds a unique prefix" find_backup 20260109
fails "find_backup rejects an ambiguous prefix" find_backup 2026
fails "find_backup rejects path characters" find_backup "../x"

test_restore() {
	ARGS=(20260105-120000)
	cmd_restore
	equals "CONFIG_N=5" "$(cat "$PERSONAL_CFG")"
}
ok "restore copies the backup into personal.config" test_restore

# --- GRUB settings ----------------------------------------------------------
test_grub_top_level() {
	DRY_RUN=no
	KEEP_BACKUPS=1
	printf 'GRUB_TIMEOUT=5\n#GRUB_TOP_LEVEL="/boot/vmlinuz-old"\n' >"$GRUB_DEFAULTS"
	set_grub_top_level 7.3.3-volfread
	equals 7.3.3-volfread "$(grub_top_level_release)"
	set_grub_top_level ""
	equals "" "$(grub_top_level_release)"
}
ok "set_grub_top_level sets and removes GRUB_TOP_LEVEL" test_grub_top_level

test_grub_short_timeout() {
	printf 'GRUB_TIMEOUT=0\nGRUB_DISABLE_LINUX_UUID=true\n' >"$GRUB_DEFAULTS"
	grub_preflight
}
fails "grub_preflight rejects GRUB_TIMEOUT below GRUB_MIN_TIMEOUT" test_grub_short_timeout

test_grub_uuid() {
	printf 'GRUB_TIMEOUT=5\n' >"$GRUB_DEFAULTS"
	USE_INITRD=no
	grub_preflight
}
fails "grub_preflight requires GRUB_DISABLE_LINUX_UUID without initrd" test_grub_uuid

# --- registry ---------------------------------------------------------------
test_registry_order() {
	touch "$STATE_DIR/7.3.10-volfread.info" "$STATE_DIR/7.3.3-e14g2.info" "$STATE_DIR/7.3.9-volfread.info"
	equals "7.3.3-e14g2 7.3.9-volfread 7.3.10-volfread" "$(registered_releases | paste -sd' ')"
}
ok "registered_releases sorts by version" test_registry_order

# --- install stage ----------------------------------------------------------
make_stage() {
	SNAPSHOT=$SANDBOX/snap
	rm -rf "$SNAPSHOT"
	mkdir -p "$SNAPSHOT/boot" "$SNAPSHOT/lib/modules/$1/kernel"
	local file
	for file in vmlinuz System.map config; do
		echo x >"$SNAPSHOT/boot/$file-$1"
	done
	echo "$1" >"$SNAPSHOT/release"
	echo log >"$SNAPSHOT/build.log"
}

test_stage_ok() {
	make_stage 7.3.3-volfread
	check_snapshot 7.3.3-volfread
}
ok "check_snapshot accepts a complete stage" test_stage_ok

test_stage_symlink() {
	make_stage 7.3.3-volfread
	ln -s /etc/shadow "$SNAPSHOT/lib/modules/7.3.3-volfread/kernel/evil.ko"
	check_snapshot 7.3.3-volfread
}
fails "check_snapshot rejects symlinks" test_stage_symlink

test_stage_extra() {
	make_stage 7.3.3-volfread
	echo x >"$SNAPSHOT/boot/grub.cfg"
	check_snapshot 7.3.3-volfread
}
fails "check_snapshot rejects files outside the expected set" test_stage_extra

test_find_stage() {
	BUILDER=$(id -un)
	local dir
	dir=$(work_dir "$(id -un)")
	mkdir -m 0700 "$dir"
	mkdir "$dir/stage"
	touch "$dir/.lock"
	echo 7.3.3-volfread >"$dir/stage/release"
	find_stage
	equals "$dir/stage" "$STAGE_DIR"
}
ok "find_stage takes BUILDER's private build directory" test_find_stage

test_find_stage_other_builder() {
	BUILDER=someone-else
	find_stage
}
fails "find_stage only takes the build of BUILDER" test_find_stage_other_builder

test_builder_root() {
	BUILDER=root
	validate_settings
}
fails "validate_settings rejects BUILDER=root" test_builder_root

test_find_stage_open() {
	BUILDER=$(id -un)
	chmod 0755 "$(work_dir "$(id -un)")"
	find_stage
}
fails "find_stage rejects a build directory others can read" test_find_stage_open

echo "passed: $PASSED, failed: $FAILED"
((FAILED == 0))
