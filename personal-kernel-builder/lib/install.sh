# shellcheck shell=bash
# Root commands that change /boot, /lib/modules and GRUB: install, uninstall, adopt.

# cmd_install: copy a staged build into the system and make it GRUB's default entry
cmd_install() {
	CURRENT_STEP=install
	require_args 0 "install [--initrd]"
	require_root install
	lock_system
	find_stage
	snapshot_stage
	local release
	release=$(<"$SNAPSHOT/release")
	valid_release "$release" || die "invalid release in the stage: $release"
	[[ $release == *"-$NAME" ]] || die "staged $release does not end in -$NAME (NAME changed? rebuild)"
	check_not_running "$release"
	check_snapshot "$release"
	grub_preflight
	check_space "$BOOT_DIR" "$MIN_FREE_BOOT_MB"
	install_files "$release"
	if [[ $USE_INITRD == yes ]]; then
		make_initrd "$release"
	elif [[ -e $BOOT_DIR/initrd-$release.img ]]; then
		# GRUB pairs any initrd named like the kernel, even one left by an older install
		info "Removing the initrd an older install of $release left"
		remove_initrd "$release"
	fi
	register_release "$release" installed
	keep_build_log "$release"
	set_grub_top_level "$release"
	update_grub "$release"
	info "Installed $release as the default kernel. Reboot, then run '$PROG verify'."
}

# find_stage: set STAGE_DIR to BUILDER's finished build
find_stage() {
	[[ -n $BUILDER ]] || die "BUILDER is not set: run '$PROG init --builder USER'"
	local dir
	dir=$(work_dir "$BUILDER")
	[[ -d $dir && ! -L $dir ]] || die "$dir not found: run '$PROG build' as $BUILDER first (before rebooting)"
	local owner mode
	read -r owner mode < <(stat -c '%U %a' -- "$dir")
	[[ $owner == "${dir##*/personal-kernel-builder-}" && $mode == 700 ]] ||
		die "$dir must belong to the user it is named after and have mode 700"
	lock_existing "$dir/.lock"
	STAGE_DIR=$dir/stage
	[[ -f $STAGE_DIR/release ]] || die "no finished build in $STAGE_DIR: run '$PROG build'"
}

# check_not_running RELEASE: refuse to replace the running kernel without --force: every
# build signs its modules with a new key, so the running kernel could not load them
check_not_running() {
	[[ $1 == "$(uname -r)" && $FORCE == no ]] || return 0
	die "$1 is the running kernel: its new modules are signed with a key it does not know, so it could not load any module until you reboot. Boot another kernel first, or pass --force"
}

# snapshot_stage: copy the user's stage into a root-only directory, so nothing can
# change it between the checks and the copy into the system. Files are read with
# BUILDER's permissions: a hard link to a file only root may read is never copied
snapshot_stage() {
	SNAPSHOT=$(mktemp -d "$BUILD_ROOT/pkb-install.XXXXXX")
	trap 'rm -rf -- "$SNAPSHOT"' EXIT
	info "Copying $STAGE_DIR to $SNAPSHOT"
	local odd path
	odd=$(find "$STAGE_DIR" -mindepth 1 ! -type f ! -type d -print -quit)
	[[ -z $odd ]] || die "unexpected symlink or special file in the stage: ${odd#"$STAGE_DIR"/}"
	local -a reader=(cat --)
	if [[ $EUID -eq 0 ]]; then
		reader=(setpriv --reuid="$BUILDER" --regid="$(id -gn -- "$BUILDER")" --init-groups -- cat --)
	fi
	# find lists each directory before its contents
	while IFS= read -r -d '' path; do
		path=${path#"$STAGE_DIR"/}
		if [[ -d $STAGE_DIR/$path ]]; then
			mkdir -m 0755 -- "$SNAPSHOT/$path"
		else
			"${reader[@]}" "$STAGE_DIR/$path" >"$SNAPSHOT/$path"
			chmod 0644 -- "$SNAPSHOT/$path"
			touch -r "$STAGE_DIR/$path" -- "$SNAPSHOT/$path"
		fi
	done < <(find "$STAGE_DIR" -mindepth 1 -print0)
}

# check_snapshot RELEASE: accept only regular files and directories in the expected places
check_snapshot() {
	local release=$1 odd
	odd=$(find "$SNAPSHOT" -mindepth 1 ! -type f ! -type d -print -quit)
	[[ -z $odd ]] || die "unexpected symlink or special file in the stage: ${odd#"$SNAPSHOT"/}"
	odd=$(find "$SNAPSHOT" -mindepth 1 -maxdepth 3 \
		! -path "$SNAPSHOT/release" ! -path "$SNAPSHOT/build.log" \
		! -path "$SNAPSHOT/boot" ! -path "$SNAPSHOT/boot/vmlinuz-$release" \
		! -path "$SNAPSHOT/boot/System.map-$release" ! -path "$SNAPSHOT/boot/config-$release" \
		! -path "$SNAPSHOT/lib" ! -path "$SNAPSHOT/lib/modules" ! -path "$SNAPSHOT/lib/modules/$release" \
		-print -quit)
	[[ -z $odd ]] || die "unexpected file in the stage: ${odd#"$SNAPSHOT"/}"
	local file
	for file in "boot/vmlinuz-$release" "boot/System.map-$release" "boot/config-$release"; do
		[[ -s $SNAPSHOT/$file ]] || die "missing $file in the stage"
	done
	[[ -d $SNAPSHOT/lib/modules/$release/kernel ]] || die "missing modules in the stage"
}

# install_files RELEASE: modules into /lib/modules, kernel files into /boot
install_files() {
	local release=$1 file
	owned_by_package "boot/vmlinuz-$release" && die "$BOOT_DIR/vmlinuz-$release belongs to a Slackware package"
	[[ $release != "$(uname -r)" ]] || warn "replacing the modules of the running kernel: it cannot load modules until you reboot"
	info "Installing modules into $MODULES_DIR/$release"
	run rm -rf -- "$MODULES_DIR/$release"
	run cp -dR --preserve=mode,timestamps -- "$SNAPSHOT/lib/modules/$release" "$MODULES_DIR/"
	run depmod -a "$release"
	info "Installing kernel files into $BOOT_DIR"
	for file in vmlinuz System.map config; do
		run cp --preserve=mode,timestamps -- "$SNAPSHOT/boot/$file-$release" "$BOOT_DIR/"
	done
}

# make_initrd RELEASE: /boot/initrd-RELEASE.img with Slackware's mkinitrd
make_initrd() {
	local release=$1 uuid fstype image tree
	uuid=${ROOT_UUID:-$(findmnt -no UUID /)}
	[[ -n $uuid ]] || die "could not determine the UUID of /"
	fstype=$(findmnt -no FSTYPE /)
	[[ -n $fstype ]] || die "could not determine the filesystem type of /"
	# GRUB only pairs an initrd named like the kernel: vmlinuz-<release> -> initrd-<release>.img
	image="$BOOT_DIR/initrd-$release.img"
	# Own tree: -c wipes it, and /boot/initrd-tree belongs to the generic kernel's initrd
	tree="$BOOT_DIR/initrd-tree-$release"
	info "Creating $image (root=UUID=$uuid${RESUME_DEV:+, resume=$RESUME_DEV})"
	local -a resume=()
	[[ -z $RESUME_DEV ]] || resume=(-h "$RESUME_DEV")
	# No -m module list: the root disk and filesystem drivers must be built in
	# (list them as NAME=y in CRITICAL_OPTIONS)
	run mkinitrd -c -k "$release" -s "$tree" -f "$fstype" -r "UUID=$uuid" "${resume[@]}" -u -o "$image"
}

# remove_initrd RELEASE: delete the initrd of RELEASE and the tree mkinitrd built it from
remove_initrd() {
	run rm -rf -- "$BOOT_DIR/initrd-$1.img" "$BOOT_DIR/initrd-tree-$1"
}

# register_release RELEASE HOW: record RELEASE so uninstall may remove it later
register_release() {
	info "Registering $1 in $STATE_DIR"
	run install -d -m 0755 "$STATE_DIR"
	if [[ $DRY_RUN == no ]]; then
		printf 'release=%s\nname=%s\n%s=%s\n' "$1" "${1##*-}" "$2" "$(date '+%F %T')" >"$STATE_DIR/$1.info"
	fi
}

# keep_build_log RELEASE: save the build log next to the tool's own log
keep_build_log() {
	run install -d -m 0755 "$LOG_DIR"
	run cp -- "$SNAPSHOT/build.log" "$LOG_DIR/build-$1-$(date +%Y%m%d-%H%M%S).log"
	prune_old "$KEEP_LOGS" "$LOG_DIR/build-*.log"
}

# grub_setting NAME: value of NAME in /etc/default/grub, without quotes
grub_setting() {
	local value
	value=$(sed -n "s/^$1=//p" "$GRUB_DEFAULTS" 2>/dev/null | tail -1 || true)
	unquote "$value"
}

# grub_uuid_disabled: true if GRUB passes root=/dev/... instead of root=UUID=
grub_uuid_disabled() {
	[[ $(grub_setting GRUB_DISABLE_LINUX_UUID) == true ]]
}

# grub_preflight: make sure a failed boot can still reach Slackware's kernel, and that
# booting without initrd gets a root= the kernel understands
grub_preflight() {
	local timeout
	timeout=$(grub_setting GRUB_TIMEOUT)
	[[ ${timeout:-5} =~ ^[0-9]+$ && ${timeout:-5} -ge $GRUB_MIN_TIMEOUT ]] ||
		check_failed "GRUB_TIMEOUT=$timeout: set it to $GRUB_MIN_TIMEOUT or more in $GRUB_DEFAULTS to pick another kernel if this one fails"
	[[ $(grub_setting GRUB_TIMEOUT_STYLE) != hidden ]] ||
		warn "GRUB_TIMEOUT_STYLE=hidden: press Esc at boot to reach the menu"
	local default
	default=$(grub_setting GRUB_DEFAULT)
	[[ -z $default || $default == 0 ]] ||
		warn "GRUB_DEFAULT=$default: GRUB_TOP_LEVEL only makes the kernel the first entry"
	if [[ $USE_INITRD == no && $FIX_GRUB_UUID == no ]] && ! grub_uuid_disabled; then
		check_failed "no initrd: set GRUB_DISABLE_LINUX_UUID=true in $GRUB_DEFAULTS, or use --fix-grub-uuid or --initrd"
	fi
}

# set_grub_setting NAME VALUE: replace NAME in /etc/default/grub, or drop it when VALUE is empty
set_grub_setting() {
	run sed -i "/^#\{0,1\}$1=/d" "$GRUB_DEFAULTS"
	[[ -z $2 ]] || append_line "$1=\"$2\"" "$GRUB_DEFAULTS"
}

# set_grub_top_level RELEASE: make RELEASE the first entry, or restore GRUB's order if empty
set_grub_top_level() {
	backup_file "$GRUB_DEFAULTS"
	if [[ $USE_INITRD == no && $FIX_GRUB_UUID == yes ]] && ! grub_uuid_disabled; then
		info "Setting GRUB_DISABLE_LINUX_UUID=true in $GRUB_DEFAULTS"
		set_grub_setting GRUB_DISABLE_LINUX_UUID true
	fi
	if [[ -n $1 ]]; then
		info "Setting GRUB_TOP_LEVEL to $BOOT_DIR/vmlinuz-$1"
		set_grub_setting GRUB_TOP_LEVEL "$BOOT_DIR/vmlinuz-$1"
	else
		info "Removing GRUB_TOP_LEVEL: GRUB picks the default kernel again"
		set_grub_setting GRUB_TOP_LEVEL ""
	fi
}

# grub_top_level_release: release GRUB_TOP_LEVEL points to, if any
grub_top_level_release() {
	local top
	top=$(grub_setting GRUB_TOP_LEVEL)
	[[ $top == "$BOOT_DIR"/vmlinuz-* ]] && echo "${top#"$BOOT_DIR"/vmlinuz-}"
	return 0
}

# update_grub [RELEASE]: regenerate grub.cfg; check RELEASE is first and a fallback remains
update_grub() {
	info "Regenerating $GRUB_CFG"
	backup_file "$GRUB_CFG"
	run grub-mkconfig -o "$GRUB_CFG"
	[[ $DRY_RUN == no ]] || return 0
	local kernels first
	kernels=$(grep -E '^[[:space:]]*linux[[:space:]]' "$GRUB_CFG" | awk '{ print $2 }' || true)
	first=$(head -1 <<<"$kernels")
	info "First GRUB entry: $first"
	if [[ -n ${1:-} && $first != */vmlinuz-"$1" ]]; then
		die "the first GRUB entry is not $1: check GRUB_TOP_LEVEL in $GRUB_DEFAULTS"
	fi
	[[ -n $kernels ]] && grep -qv -- "/vmlinuz-${1:-none}\$" <<<"$kernels" ||
		warn "$GRUB_CFG has no other kernel to fall back to"
}

# cmd_uninstall: remove registered personal kernels and fix GRUB's default
cmd_uninstall() {
	CURRENT_STEP=uninstall
	require_root uninstall
	local -a targets
	if [[ -n $KEEP_KERNELS ]]; then
		require_args 0 "uninstall --keep N"
		mapfile -t targets < <(registered_releases | head -n "-$KEEP_KERNELS")
	else
		require_args 1 "uninstall <release> | --keep N"
		targets=("${ARGS[0]}")
	fi
	((${#targets[@]})) || { info "Nothing to uninstall"; return 0; }
	lock_system
	local release top removed=no count=0
	top=$(grub_top_level_release)
	for release in "${targets[@]}"; do
		valid_release "$release" || die "invalid release: $release"
		is_registered "$release" || die "$release is not registered (see '$PROG status'; '$PROG adopt' it first)"
		if [[ $release == "$(uname -r)" ]]; then
			[[ -n $KEEP_KERNELS ]] || die "$release is the running kernel"
			warn "keeping $release: it is the running kernel"
			continue
		fi
		remove_release "$release"
		count=$((count + 1))
		[[ $release != "$top" ]] || removed=yes
	done
	((count)) || { info "Nothing was removed"; return 0; }
	if [[ $removed == yes ]]; then
		set_grub_top_level "$(newest_installed)"
	fi
	update_grub
}

# remove_release RELEASE: delete the files install puts in /boot and /lib/modules
remove_release() {
	local release=$1
	owned_by_package "boot/vmlinuz-$release" && die "$BOOT_DIR/vmlinuz-$release belongs to a Slackware package"
	info "Removing $release"
	run rm -f -- "$BOOT_DIR/vmlinuz-$release" "$BOOT_DIR/System.map-$release" "$BOOT_DIR/config-$release"
	run rm -rf -- "$MODULES_DIR/$release"
	remove_initrd "$release"
	run rm -f -- "$STATE_DIR/$release.info"
}

# newest_installed: newest registered release whose kernel is still in /boot
newest_installed() {
	local release newest=""
	while read -r release; do
		[[ ! -f $BOOT_DIR/vmlinuz-$release ]] || newest=$release
	done < <(registered_releases)
	echo "$newest"
}

# cmd_adopt: register a personal kernel installed by other means, so uninstall can remove it
cmd_adopt() {
	CURRENT_STEP=adopt
	require_root adopt
	require_args 1 "adopt <release>"
	local release=${ARGS[0]}
	valid_release "$release" || die "invalid release: $release"
	[[ -f $BOOT_DIR/vmlinuz-$release ]] || die "$BOOT_DIR/vmlinuz-$release not found"
	owned_by_package "boot/vmlinuz-$release" && die "$release belongs to a Slackware package"
	is_registered "$release" && die "$release is already registered"
	register_release "$release" adopted
}
