# shellcheck shell=bash
# Configuration commands: init, config, diff, backup, restore.

# cmd_init: create ETC_DIR, import Slackware's default config and the personal one,
# and point at unregistered personal kernels
cmd_init() {
	CURRENT_STEP=init
	require_root init
	require_args 0 "init [--name NAME] [--builder USER] [--config FILE]"
	# Whoever logged in before su is the usual builder
	BUILDER=${BUILDER:-$(logname 2>/dev/null || true)}
	[[ -n $BUILDER && $BUILDER != root ]] || die "who builds the kernel? run '$PROG init --builder USER'"
	validate_settings
	id -u -- "$BUILDER" >/dev/null 2>&1 || die "user $BUILDER does not exist"
	run install -d -m 0755 -o root -g root "$ETC_DIR" "$LOG_DIR" "$STATE_DIR"
	run install -d -m 0755 -o "$BUILDER" -g root "$BACKUP_DIR"
	save_setting NAME "$NAME"
	save_setting BUILDER "$BUILDER"
	import_default_config
	import_personal_config
	hand_over_to_builder
	list_unregistered
	info "Ready: as $BUILDER run '$PROG build', then '$PROG install' as root."
}

# save_setting KEY VALUE: store KEY=VALUE in CONF_FILE (creating it if needed)
save_setting() {
	local key=$1 value=$2
	[[ -f $CONF_FILE ]] || create_conf
	[[ $(sed -n "s/^$key=//p" "$CONF_FILE" 2>/dev/null) != "$value" ]] || return 0
	info "Setting $key=$value in $CONF_FILE"
	backup_file "$CONF_FILE"
	run sed -i "/^$key=/d" "$CONF_FILE"
	append_line "$key=$value" "$CONF_FILE"
}

# create_conf: start CONF_FILE from the package's template, so CRITICAL_OPTIONS and the
# other defaults are not silently missing
create_conf() {
	if [[ -f $CONF_FILE.new ]]; then
		info "Creating $CONF_FILE from $CONF_FILE.new"
		run install -m 0644 -o root -g root -- "$CONF_FILE.new" "$CONF_FILE"
	else
		warn "creating an empty $CONF_FILE: CRITICAL_OPTIONS and VERIFY_MODULES are not set"
		run install -m 0644 -o root -g root /dev/null "$CONF_FILE"
	fi
}

# hand_over_to_builder: make BUILDER the owner of personal.config and its backups
hand_over_to_builder() {
	run chown -- "$BUILDER" "$BACKUP_DIR"
	[[ ! -e $PERSONAL_CFG && $DRY_RUN == no ]] || run chown -- "$BUILDER" "$PERSONAL_CFG"
	# Only regular files: -type f never matches a symlink planted in the directory
	run find "$BACKUP_DIR" -maxdepth 1 -type f -name 'personal-*.config' -exec chown -- "$BUILDER" {} +
}

# import_default_config: copy the config /boot/config points to and remember its origin
import_default_config() {
	local origin
	origin=$(readlink -f -- "$SLACKWARE_CONFIG") || die "$SLACKWARE_CONFIG not found"
	[[ -f $origin ]] || die "$SLACKWARE_CONFIG points to missing $origin"
	info "Importing Slackware's default config from $origin"
	run install -m 0644 -o root -g root -- "$origin" "$DEFAULT_CFG"
	if [[ $DRY_RUN == no ]]; then
		echo "$origin" >"$DEFAULT_ORIGIN"
	fi
}

# import_personal_config: install --config FILE, or start from the default config
import_personal_config() {
	local source=$IMPORT_CONFIG
	if [[ -z $source ]]; then
		[[ ! -f $PERSONAL_CFG ]] || return 0
		source=$DEFAULT_CFG
		warn "no --config: personal.config starts as Slackware's default config (rerun init with --config FILE to use yours)"
	fi
	[[ -f $source ]] || check_failed "config not found: $source"
	backup_personal
	info "Installing $source as $PERSONAL_CFG (LOCALVERSION -$NAME)"
	run install -m 0644 -o "$BUILDER" -g root -- "$source" "$PERSONAL_CFG"
	if [[ $DRY_RUN == no ]]; then
		set_localversion "$PERSONAL_CFG"
	fi
}

# list_unregistered: point at personal kernels in /boot that uninstall does not know about
list_unregistered() {
	local kernel release
	for kernel in /boot/vmlinuz-*; do
		[[ -f $kernel && ! -L $kernel ]] || continue
		release=${kernel#/boot/vmlinuz-}
		valid_release "$release" || continue
		is_registered "$release" && continue
		owned_by_package "boot/vmlinuz-$release" && continue
		info "Unregistered personal kernel $release: '$PROG adopt $release' lets uninstall remove it"
	done
}

# cmd_config: run olddefconfig or menuconfig on personal.config in the private source copy
cmd_config() {
	local action=${ARGS[0]:-}
	CURRENT_STEP="config $action"
	require_args 1 "config olddefconfig|menuconfig"
	[[ $action == olddefconfig || $action == menuconfig ]] || die "usage: $PROG config olddefconfig|menuconfig"
	require_no_dry_run config
	[[ -w $PERSONAL_CFG ]] || die "cannot write $PERSONAL_CFG (run init as root; is BUILDER=${BUILDER:-unset} you?)"
	# olddefconfig keeps every value it can: a missing option is already missing here
	if [[ $action == olddefconfig ]] && ! (check_critical "$PERSONAL_CFG" && check_signing "$PERSONAL_CFG"); then
		die "fix $PERSONAL_CFG with '$PROG config menuconfig' or '$PROG restore <id>' (see '$PROG backup list')"
	fi
	prepare_tree
	cp -- "$PERSONAL_CFG" "$TREE/.config"
	set_localversion "$TREE/.config"
	make -C "$TREE" -s "$action"
	if ! (check_critical "$TREE/.config" && check_signing "$TREE/.config"); then
		cp -- "$TREE/.config" "$WORK_DIR/rejected.config"
		die "$PERSONAL_CFG not changed; the rejected result is in $WORK_DIR/rejected.config"
	fi
	if cmp -s -- "$PERSONAL_CFG" "$TREE/.config"; then
		info "$PERSONAL_CFG unchanged"
		return 0
	fi
	backup_personal
	report_changes "$PERSONAL_CFG" "$TREE/.config"
	replace_contents "$TREE/.config" "$PERSONAL_CFG"
	info "Saved $PERSONAL_CFG"
}

# report_changes OLD NEW: summarise the options NEW changed from OLD
report_changes() {
	local changes
	changes=$(config_changes "$1" "$2")
	if [[ -z $changes ]]; then
		info "No option of $1 changed value (only new options were added)"
		return 0
	fi
	info "$(wc -l <<<"$changes") option(s) changed value:"
	head -20 <<<"$changes"
}

# cmd_diff: compare personal.config with the default, the running kernel or a backup
cmd_diff() {
	CURRENT_STEP="diff"
	((${#ARGS[@]} <= 1)) || die "usage: $PROG diff [default|running|<backup id>]"
	local target=${ARGS[0]:-default} other unpacked=""
	case $target in
	default) other=$DEFAULT_CFG ;;
	running)
		other="/boot/config-$(uname -r)"
		if [[ -r /proc/config.gz ]]; then
			unpacked=$(mktemp)
			zcat /proc/config.gz >"$unpacked"
			other=$unpacked
		fi
		;;
	*) other=$(find_backup "$target") ;;
	esac
	[[ -f $other ]] || die "nothing to compare: $other not found (run init?)"
	info "Changes from ${unpacked:+/proc/config.gz via }$other to $PERSONAL_CFG"
	show_diff "$other" "$PERSONAL_CFG"
	[[ -z $unpacked ]] || rm -f -- "$unpacked"
}

# show_diff OLD NEW: config differences, with the kernel's diffconfig when available
show_diff() {
	if [[ -x $SRC_DIR/scripts/diffconfig ]]; then
		"$SRC_DIR/scripts/diffconfig" "$1" "$2"
	else
		diff -u -- "$1" "$2" || (($? == 1))
	fi
}

# backup_personal: version personal.config by date unless the newest backup is identical
backup_personal() {
	[[ -f $PERSONAL_CFG ]] || return 0
	local newest
	# compgen fails when there is no backup yet: that is not an error
	newest=$(compgen -G "$BACKUP_DIR/personal-*.config" | sort | tail -1 || true)
	if [[ -n $newest ]] && cmp -s -- "$newest" "$PERSONAL_CFG"; then
		return 0
	fi
	local copy
	copy="$BACKUP_DIR/personal-$(date +%Y%m%d-%H%M%S).config"
	info "Backing up $PERSONAL_CFG to $copy"
	as_builder cp -- "$PERSONAL_CFG" "$copy"
	prune_old "$KEEP_BACKUPS" "$BACKUP_DIR/personal-*.config"
}

# find_backup ID: the single backup whose timestamp starts with ID (YYYYmmdd[-HHMMSS])
find_backup() {
	[[ $1 =~ ^[0-9][0-9-]*$ ]] || die "backup id must look like YYYYmmdd-HHMMSS: $1"
	local -a matches
	mapfile -t matches < <(compgen -G "$BACKUP_DIR/personal-$1*.config")
	((${#matches[@]} == 1)) || die "backup id $1 matches ${#matches[@]} backups (see '$PROG backup list')"
	echo "${matches[0]}"
}

# cmd_backup: back up personal.config now, or list the backups
cmd_backup() {
	CURRENT_STEP=backup
	case ${ARGS[*]} in
	"") [[ -w $BACKUP_DIR ]] || die "cannot write $BACKUP_DIR"; backup_personal ;;
	list) list_backups ;;
	*) die "usage: $PROG backup [list]" ;;
	esac
}

# list_backups: backup ids, newest first
list_backups() {
	local file id
	while read -r file; do
		id=${file##*/personal-}
		echo "${id%.config}"
	done < <(compgen -G "$BACKUP_DIR/personal-*.config" | sort -r)
}

# cmd_restore: replace personal.config with a backup (the current one is backed up first)
cmd_restore() {
	CURRENT_STEP=restore
	require_args 1 "restore <backup id>"
	[[ -w $PERSONAL_CFG ]] || die "cannot write $PERSONAL_CFG"
	local backup
	backup=$(find_backup "${ARGS[0]}")
	backup_personal
	report_changes "$PERSONAL_CFG" "$backup"
	replace_contents "$backup" "$PERSONAL_CFG"
	info "Restored $backup; run '$PROG config olddefconfig' before building"
}
