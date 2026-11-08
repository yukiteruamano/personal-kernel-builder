# shellcheck shell=bash
# Build commands: check and build. Everything here runs without root, in a private
# copy of the sources under BUILD_ROOT, so /usr/src/linux stays as Slackware ships it.

# make_private_dir DIR: create DIR (mode 0700) or accept it only if it is ours and private
make_private_dir() {
	local dir=$1 owner mode
	[[ ! -L $dir ]] || die "$dir is a symlink"
	[[ -d $dir ]] || mkdir -m 0700 -- "$dir"
	read -r owner mode < <(stat -c '%u %a' -- "$dir")
	[[ $owner == "$EUID" && $mode == 700 ]] || die "$dir must be a directory owned by you with mode 700"
}

# prepare_tree: lock WORK_DIR and set TREE to a private copy of SRC_DIR, reusing the
# copy (and its objects) while the sources stay the same
prepare_tree() {
	WORK_DIR=$(work_dir "$(id -un)")
	make_private_dir "$WORK_DIR"
	lock_file "$WORK_DIR/.lock"
	TREE=$WORK_DIR/src
	[[ -f $SRC_DIR/Makefile ]] || die "$SRC_DIR/Makefile not found (is kernel-source installed?)"
	local source origin
	source=$(readlink -f -- "$SRC_DIR")
	origin="$source $(stat -c %Y -- "$source/Makefile")"
	if [[ -f $TREE/.pkb-origin && $(<"$TREE/.pkb-origin") == "$origin" ]]; then
		return 0
	fi
	check_space "$BUILD_ROOT" "$MIN_FREE_BUILD_MB"
	info "Copying $source to $TREE"
	rm -rf -- "$TREE"
	cp -R --preserve=mode,timestamps -- "$source" "$TREE"
	# Slackware's kernel-source ships a configured tree: start from a pristine one
	make -C "$TREE" -s mrproper
	echo "$origin" >"$TREE/.pkb-origin"
}

# cmd_check: validate everything needed before building (read-only)
cmd_check() {
	CURRENT_STEP=check
	require_args 0 check
	info "Checking sources in $SRC_DIR"
	[[ -f $SRC_DIR/Makefile ]] || die "$SRC_DIR/Makefile not found (is kernel-source installed?)"
	[[ -r $PERSONAL_CFG ]] || die "$PERSONAL_CFG not found: run '$PROG init' as root"
	local src_ver cfg_ver
	src_ver=$(src_version)
	cfg_ver=$(sed -n 's/^# Linux\/x86 \([^ ]*\) Kernel Configuration$/\1/p' "$PERSONAL_CFG")
	[[ $src_ver == "$cfg_ver" ]] ||
		warn "sources are $src_ver but personal.config was made for ${cfg_ver:-unknown}: run '$PROG config olddefconfig'"
	check_critical "$PERSONAL_CFG"
	check_signing "$PERSONAL_CFG"
	[[ $(config_value LOCALVERSION "$PERSONAL_CFG") == "-$NAME" ]] ||
		warn "personal.config LOCALVERSION is not -$NAME (build sets it anyway)"
	check_default_origin
	local tool missing=()
	for tool in make gcc ld flex bison bc perl openssl zstd depmod grub-mkconfig flock; do
		command -v "$tool" >/dev/null || missing+=("$tool")
	done
	if [[ $USE_INITRD == yes ]]; then
		command -v mkinitrd >/dev/null || missing+=(mkinitrd)
	fi
	((${#missing[@]} == 0)) || check_failed "missing tools: ${missing[*]}"
	check_space "$BUILD_ROOT" "$MIN_FREE_BUILD_MB"
	check_space "$BOOT_DIR" "$MIN_FREE_BOOT_MB"
	check_space "$MODULES_DIR" "$MIN_FREE_MODULES_MB"
	grub_preflight
	[[ -d /sys/firmware/efi ]] || warn "not booted in UEFI mode"
	info "Release to build: $(expected_release)"
}

# check_default_origin: warn when /boot/config moved since init imported it
check_default_origin() {
	[[ -f $DEFAULT_ORIGIN ]] || return 0
	local now
	now=$(readlink -f -- "$SLACKWARE_CONFIG" 2>/dev/null || true)
	[[ $now == "$(<"$DEFAULT_ORIGIN")" ]] ||
		warn "$SLACKWARE_CONFIG now points to ${now:-nothing}: run '$PROG init' to import the new default"
}

# cmd_build: compile personal.config in the private tree and stage the result for install
cmd_build() {
	CURRENT_STEP=build
	require_args 0 "build [--jobs N]"
	require_user build
	require_no_dry_run build
	[[ -r $PERSONAL_CFG ]] || die "$PERSONAL_CFG not found: run '$PROG init' as root"
	[[ $(id -un) == "$BUILDER" ]] || warn "install only takes the build of BUILDER=${BUILDER:-unset}, not $(id -un)"
	prepare_tree
	cd "$TREE" || die "cannot enter $TREE"
	cp -- "$PERSONAL_CFG" .config
	set_localversion .config
	# The kernel generates this key when it is missing: a fresh one for every build
	set_config_str .config MODULE_SIG_KEY certs/signing_key.pem
	rm -f -- certs/signing_key.pem certs/signing_key.x509
	make -s olddefconfig
	check_critical .config
	check_signing .config
	local changes
	changes=$(config_changes "$PERSONAL_CFG" .config)
	if [[ -n $changes ]]; then
		head -20 <<<"$changes" >&2
		die "personal.config does not match these sources: run '$PROG config olddefconfig' first"
	fi
	local release log start=$SECONDS elapsed
	release=$(make -s kernelrelease)
	[[ $release == *"-$NAME" ]] || die "kernel release $release does not end in -$NAME"
	log=$WORK_DIR/build.log
	info "Compiling $release with $JOBS jobs (log: $log)"
	make -j"$JOBS" 2>&1 | tee "$log"
	stage_build "$release"
	elapsed=$((SECONDS - start))
	info "Built $release in $((elapsed / 60))m$((elapsed % 60))s: run '$PROG install' as root before rebooting"
}

# stage_build RELEASE: install modules and kernel files into WORK_DIR/stage, the only
# thing install (root) reads, so root never runs make on this tree
stage_build() {
	local release=$1 stage=$WORK_DIR/stage
	info "Staging $release in $stage"
	rm -rf -- "$stage"
	mkdir -p -- "$stage/boot"
	make -s INSTALL_MOD_PATH="$stage" modules_install
	[[ -d $stage/lib/modules/$release ]] || die "modules_install did not create $stage/lib/modules/$release"
	# They point into BUILD_ROOT, which does not survive a reboot
	rm -f -- "$stage/lib/modules/$release/build" "$stage/lib/modules/$release/source"
	cp -- arch/x86/boot/bzImage "$stage/boot/vmlinuz-$release"
	cp -- System.map "$stage/boot/System.map-$release"
	cp -- .config "$stage/boot/config-$release"
	cp -- "$WORK_DIR/build.log" "$stage/build.log"
	echo "$release" >"$stage/release"
	# Modules are signed by now: without the private key nothing else can be signed for this kernel
	rm -f -- certs/signing_key.pem
}
