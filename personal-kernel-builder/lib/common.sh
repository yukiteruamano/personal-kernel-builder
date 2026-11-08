# shellcheck shell=bash
# Shared helpers: paths, settings, messages, dry-run, locking and kernel config parsing.

ETC_DIR=/etc/personal-kernel-builder
CONF_FILE=$ETC_DIR/personal-kernel-builder.conf
DEFAULT_CFG=$ETC_DIR/default.config
DEFAULT_ORIGIN=$ETC_DIR/default.origin
PERSONAL_CFG=$ETC_DIR/personal.config
BACKUP_DIR=$ETC_DIR/backups
LOG_DIR=/var/log/personal-kernel-builder
LOG_FILE=$LOG_DIR/personal-kernel-builder.log
STATE_DIR=/var/lib/personal-kernel-builder/installed
LOCK_FILE=/var/lock/personal-kernel-builder.lock
GRUB_CFG=/boot/grub/grub.cfg
GRUB_DEFAULTS=/etc/default/grub
SLACKWARE_CONFIG=/boot/config
# Free space (MiB): source copy + objects in BUILD_ROOT, kernel files, modules
MIN_FREE_BUILD_MB=6144
MIN_FREE_BOOT_MB=100
MIN_FREE_MODULES_MB=512
# Symbols derived from the compiler or forced by the tool: ignored when comparing configs
IGNORED_SYMBOLS='^CONFIG_(CC_|GCC_|CLANG_|AS_|LD_|RUSTC_|RUST_|BINDGEN_|PAHOLE_|TOOLS_SUPPORT_|LOCALVERSION=|MODULE_SIG_KEY=)'

# Settings: defaults, overridden by CONF_FILE and then by command-line options
NAME=""
SRC_DIR=/usr/src/linux
BUILD_ROOT=/tmp
JOBS=4
KEEP_BACKUPS=7
KEEP_LOGS=7
BUILDER=""
USE_INITRD=no
RESUME_DEV=""
ROOT_UUID=""
GRUB_MIN_TIMEOUT=3
CRITICAL_OPTIONS=""
VERIFY_MODULES=""
VERIFY_BATTERY=no

# Per-run state
DRY_RUN=no
FIX_GRUB_UUID=no
KEEP_KERNELS=""
IMPORT_CONFIG=""
ARGS=()
CURRENT_STEP=setup

# die MESSAGE: print an error to stderr and exit non-zero
die() {
	echo "error: $*" >&2
	exit 1
}

# warn MESSAGE: print a warning to stderr
warn() {
	echo "warning: $*" >&2
}

# info MESSAGE: progress message
info() {
	echo "==> $*"
}

# on_error LINE STATUS: ERR trap, name the step and line that failed
# (only in the main shell, so a failing $(...) is not reported twice)
on_error() {
	[[ $BASHPID == "$$" ]] || return 0
	echo "error: step '$CURRENT_STEP' failed at line $1 (exit $2)" >&2
}

# check_failed MESSAGE: abort, or only warn in --dry-run
check_failed() {
	[[ $DRY_RUN == yes ]] || die "$1"
	warn "$1 (ignored in dry-run)"
}

# run CMD...: execute a command that changes the system, or only print it with --dry-run
run() {
	if [[ $DRY_RUN == yes ]]; then
		printf '[dry-run]'
		printf ' %q' "$@"
		printf '\n'
	else
		"$@"
	fi
}

# append_line LINE FILE: add LINE at the end of FILE (honours --dry-run)
append_line() {
	if [[ $DRY_RUN == yes ]]; then
		printf '[dry-run] append %q to %q\n' "$1" "$2"
	else
		printf '%s\n' "$1" >>"$2"
	fi
}

# replace_contents SRC DST: overwrite DST in place, keeping its owner, group and mode
# (lets BUILDER update files it owns in directories only root can write)
replace_contents() {
	if [[ $DRY_RUN == yes ]]; then
		printf '[dry-run] write %q into %q\n' "$1" "$2"
	else
		cat -- "$1" >"$2"
	fi
}

# require_root COMMAND: refuse to touch the system unless running as root (or dry-run)
require_root() {
	[[ $DRY_RUN == yes || $EUID -eq 0 ]] || die "'$1' needs root (try: su -c '$PROG $1')"
}

# require_user COMMAND: refuse to compile as root
require_user() {
	[[ $EUID -ne 0 ]] || die "'$1' must not run as root: run it as ${BUILDER:-your user}"
}

# as_builder CMD...: run CMD as BUILDER when root, so root never writes into BUILDER's
# directories (a planted symlink there would redirect root's write)
as_builder() {
	if [[ $EUID -eq 0 ]]; then
		[[ -n $BUILDER ]] || die "BUILDER is not set: run '$PROG init --builder USER'"
		run setpriv --reuid="$BUILDER" --regid="$(id -gn -- "$BUILDER")" --init-groups -- "$@"
	else
		run "$@"
	fi
}

# require_no_dry_run COMMAND: commands that only touch the user's build tree have no dry-run
require_no_dry_run() {
	[[ $DRY_RUN == no ]] || die "--dry-run is not supported by '$1'"
}

# require_args COUNT USAGE: check the number of positional arguments of a command
require_args() {
	((${#ARGS[@]} == $1)) || die "usage: $PROG $2"
}

# lock_file FILE: take an exclusive lock on FILE for the rest of the run
lock_file() {
	exec 9>"$1"
	flock -n 9 || die "another $PROG run holds $1"
}

# lock_system: serialise the commands that change /boot, /lib/modules and GRUB
lock_system() {
	[[ $DRY_RUN == yes ]] || lock_file "$LOCK_FILE"
}

# lock_existing FILE: lock a file owned by someone else without creating or truncating it
lock_existing() {
	[[ -f $1 && ! -L $1 ]] || die "lock file $1 missing or not a regular file"
	exec 8<"$1"
	flock -n 8 || die "a build is still running ($1 is locked)"
}

# prune_old KEEP PATTERN: keep only the newest KEEP files matching PATTERN
# (names end in a sortable timestamp)
prune_old() {
	local keep=$1 old
	local -a files
	mapfile -t files < <(compgen -G "$2" | sort -r)
	for old in "${files[@]:keep}"; do
		run rm -f -- "$old"
	done
}

# backup_file FILE: copy FILE to FILE.bak-<timestamp> if it exists, then rotate old copies
backup_file() {
	[[ -e $1 ]] || return 0
	run cp -a -- "$1" "$1.bak-$(date +%Y%m%d-%H%M%S)"
	prune_old "$KEEP_BACKUPS" "$1.bak-*"
}

# unquote VALUE: strip one pair of surrounding single or double quotes
unquote() {
	local value=$1
	if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
		value=${BASH_REMATCH[1]}
	fi
	printf '%s' "$value"
}

# check_root_owned FILE: refuse files root does not own or others can modify
check_root_owned() {
	local owner mode
	read -r owner mode < <(stat -c '%u %a' -- "$1")
	[[ $owner == 0 ]] || die "$1 must be owned by root"
	((8#$mode & 8#022)) && die "$1 must not be writable by group or others"
	return 0
}

# load_conf: read KEY=VALUE settings from CONF_FILE without executing it
load_conf() {
	[[ -f $CONF_FILE ]] || return 0
	check_root_owned "$CONF_FILE"
	local line key lineno=0
	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([A-Z_]+)=(.*)$ ]] || die "$CONF_FILE:$lineno: expected KEY=VALUE"
		key=${BASH_REMATCH[1]}
		case $key in
		NAME | SRC_DIR | BUILD_ROOT | JOBS | KEEP_BACKUPS | KEEP_LOGS | BUILDER | USE_INITRD | \
			RESUME_DEV | ROOT_UUID | GRUB_MIN_TIMEOUT | CRITICAL_OPTIONS | VERIFY_MODULES | VERIFY_BATTERY)
			printf -v "$key" '%s' "$(unquote "${BASH_REMATCH[2]}")"
			;;
		*) die "$CONF_FILE:$lineno: unknown setting $key" ;;
		esac
	done <"$CONF_FILE"
}

# valid_name NAME: lowercase kernel suffix, safe inside /boot and /lib/modules paths
valid_name() {
	[[ $1 =~ ^[a-z0-9][a-z0-9._-]{0,31}$ ]]
}

# validate_settings: reject settings that would build or install the wrong thing
validate_settings() {
	if [[ -z $NAME ]]; then
		[[ ! -f $CONF_FILE.new ]] || warn "$CONF_FILE.new (from the package) is not merged into $CONF_FILE"
		[[ -f $CONF_FILE ]] || die "NAME is not set and $CONF_FILE does not exist: pass --name NAME to init"
		die "NAME is not set in $CONF_FILE: add NAME=... there, or pass --name NAME to init"
	fi
	valid_name "$NAME" || die "NAME '$NAME' must match [a-z0-9][a-z0-9._-]{0,31}"
	[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die "JOBS must be a positive number"
	[[ $KEEP_BACKUPS =~ ^[1-9][0-9]*$ ]] || die "KEEP_BACKUPS must be a positive number"
	[[ $KEEP_LOGS =~ ^[1-9][0-9]*$ ]] || die "KEEP_LOGS must be a positive number"
	[[ $GRUB_MIN_TIMEOUT =~ ^[0-9]+$ ]] || die "GRUB_MIN_TIMEOUT must be a number"
	[[ -z $KEEP_KERNELS || $KEEP_KERNELS =~ ^[1-9][0-9]*$ ]] || die "--keep must be a positive number"
	[[ $USE_INITRD == yes || $USE_INITRD == no ]] || die "USE_INITRD must be yes or no"
	[[ $VERIFY_BATTERY == yes || $VERIFY_BATTERY == no ]] || die "VERIFY_BATTERY must be yes or no"
	[[ $SRC_DIR == /* && $BUILD_ROOT == /* ]] || die "SRC_DIR and BUILD_ROOT must be absolute paths"
	[[ -z $BUILDER || $BUILDER =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid BUILDER '$BUILDER'"
	[[ $BUILDER != root ]] || die "BUILDER must not be root: builds run without privileges"
}

# start_log COMMAND: as root, copy the output of the commands that change the system into
# LOG_FILE (never menuconfig: its screen needs the terminal, not a pipe)
start_log() {
	[[ $EUID -eq 0 && $DRY_RUN == no ]] || return 0
	[[ $1 == @(init|install|uninstall|adopt) ]] || return 0
	install -d -m 0755 "$LOG_DIR"
	exec > >(tee -a "$LOG_FILE") 2>&1
	echo "### $(date '+%F %T') $PROG $1 ${ARGS[*]}"
}

# valid_release RELEASE: kernel release string without path characters
valid_release() {
	[[ $1 =~ ^[0-9]+\.[0-9]+[A-Za-z0-9._+-]*$ ]]
}

# config_value NAME FILE: value of CONFIG_NAME in FILE
config_value() {
	sed -n "s/^CONFIG_$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}$/\1/p" "$2"
}

# set_config_str FILE NAME VALUE: set CONFIG_NAME="VALUE" in FILE
set_config_str() {
	local file=$1 name=$2 value=$3
	sed -i "/^# CONFIG_$name is not set$/d" "$file"
	if grep -q "^CONFIG_$name=" "$file"; then
		sed -i "s|^CONFIG_$name=.*|CONFIG_$name=\"$value\"|" "$file"
	else
		printf 'CONFIG_%s="%s"\n' "$name" "$value" >>"$file"
	fi
}

# set_localversion FILE: make the release end in -NAME and nothing else
set_localversion() {
	set_config_str "$1" LOCALVERSION "-$NAME"
	sed -i 's/^CONFIG_LOCALVERSION_AUTO=y$/# CONFIG_LOCALVERSION_AUTO is not set/' "$1"
}

# check_critical FILE: fail if any CRITICAL_OPTIONS entry is not enabled as required in FILE
# (NAME means y or m, NAME=y means built in)
check_critical() {
	local file=$1 entry name want value
	local -a entries bad=()
	if [[ -z $CRITICAL_OPTIONS ]]; then
		warn "CRITICAL_OPTIONS is empty in $CONF_FILE: no option of $file is checked"
		return 0
	fi
	read -ra entries <<<"$CRITICAL_OPTIONS"
	for entry in "${entries[@]}"; do
		name=${entry%%=*}
		want=${entry#"$name"}
		value=$(config_value "$name" "$file")
		if [[ -n $want ]]; then
			[[ "=$value" == "$want" ]] || bad+=("$name=${value:-unset} (needs ${want#=})")
		else
			[[ $value == [ym] ]] || bad+=("$name=${value:-unset} (needs y or m)")
		fi
	done
	((${#bad[@]} == 0)) || die "critical options wrong in $file: ${bad[*]}"
}

# check_signing FILE: with MODULE_SIG, modules must be signed during the build, because
# build deletes the private key afterwards
check_signing() {
	[[ $(config_value MODULE_SIG "$1") != y || $(config_value MODULE_SIG_ALL "$1") == y ]] ||
		die "CONFIG_MODULE_SIG_ALL must be y in $1: the signing key only exists during the build"
}

# config_changes WANTED RESULT: options of WANTED whose value differs in RESULT;
# "n" is a disabled option, "(gone)" a symbol RESULT does not have at all
config_changes() {
	awk -v skip="$IGNORED_SYMBOLS" '
		/^CONFIG_/ { i = index($0, "="); name = substr($0, 1, i - 1); value = substr($0, i + 1) }
		/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { name = $2; value = "n" }
		!/^CONFIG_/ && !/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { next }
		(name "=") ~ skip { next }
		FNR == NR { want[name] = value; next }
		{ got[name] = value }
		END {
			# test "in" first: reading got[name] would create the entry
			for (name in want)
				if (!(name in got)) {
					# a disabled symbol that no longer exists changes nothing
					if (want[name] != "n")
						printf "%s: %s -> (gone)\n", name, want[name]
				} else if (want[name] != got[name])
					printf "%s: %s -> %s\n", name, want[name], got[name]
		}
	' "$1" "$2" | sort
}

# src_version: VERSION.PATCHLEVEL.SUBLEVEL plus EXTRAVERSION of SRC_DIR
src_version() {
	awk -F' = ' '
		$1 == "VERSION" { v = $2 } $1 == "PATCHLEVEL" { p = $2 }
		$1 == "SUBLEVEL" { s = $2 } $1 == "EXTRAVERSION" { e = $2 }
		END { if (v != "") printf "%s.%s.%s%s\n", v, p, s, e }
	' "$SRC_DIR/Makefile"
}

# expected_release: release the current sources and NAME produce
expected_release() {
	echo "$(src_version)-$NAME"
}

# check_space PATH MIN_MB: fail if the filesystem holding PATH has less than MIN_MB free
check_space() {
	local path=$1 min=$2 free
	# The target may not exist yet: measure the closest parent
	while [[ ! -e $path ]]; do
		path=$(dirname -- "$path")
	done
	free=$(df -Pm -- "$path" | awk 'NR == 2 { print $4 }')
	((free >= min)) || check_failed "only ${free} MiB free for $path (needs ${min} MiB)"
}

# package_db: directory of Slackware's installed-package lists
package_db() {
	if [[ -d /var/lib/pkgtools/packages ]]; then
		echo /var/lib/pkgtools/packages
	else
		echo /var/log/packages
	fi
}

# owned_by_package PATH: true if a Slackware package lists PATH (no leading slash)
owned_by_package() {
	grep -qxF -- "$1" "$(package_db)"/* 2>/dev/null
}

# registered_releases: personal kernels known to install/adopt, oldest first
registered_releases() {
	local info
	for info in "$STATE_DIR"/*.info; do
		[[ -e $info ]] || continue
		basename -- "$info" .info
	done | sort -V
}

# is_registered RELEASE: true if RELEASE was installed or adopted
is_registered() {
	[[ -f $STATE_DIR/$1.info ]]
}

# work_dir USER: private build directory of USER under BUILD_ROOT
work_dir() {
	echo "$BUILD_ROOT/personal-kernel-builder-$1"
}
