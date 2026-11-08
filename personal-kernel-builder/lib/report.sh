# shellcheck shell=bash
# Read-only reports: verify (the running kernel) and status (everything the tool manages).

# sysfs_read FILE: contents of a sysfs attribute, or "n/a" when missing
sysfs_read() {
	cat -- "$1" 2>/dev/null || echo n/a
}

# amd_pmc_device_present: true when firmware exposes the AMD PMC (AMDI0005+),
# which only happens with s0ix ("Windows and Linux" sleep state in the BIOS)
amd_pmc_device_present() {
	compgen -G '/sys/bus/acpi/devices/AMDI000[5-9AB]:*' >/dev/null
}

# verify_charging: show AC/BAT0 state and explain why the battery is not charging;
# fails only when there is no known reason
verify_charging() {
	local ps=/sys/class/power_supply
	local ac status capacity start stop behaviour
	ac=$(sysfs_read "$ps/AC/online")
	status=$(sysfs_read "$ps/BAT0/status")
	capacity=$(sysfs_read "$ps/BAT0/capacity")
	start=$(sysfs_read "$ps/BAT0/charge_control_start_threshold")
	stop=$(sysfs_read "$ps/BAT0/charge_control_end_threshold")
	behaviour=$(sysfs_read "$ps/BAT0/charge_behaviour")
	info "AC online=$ac, BAT0 status=$status capacity=$capacity% thresholds=$start-$stop% behaviour=$behaviour"
	if [[ $status == n/a ]]; then
		warn "BAT0 not found (ACPI_BATTERY missing or battery not detected)"
		return 1
	fi
	[[ $ac == 1 && $status != Charging && $status != Full ]] || return 0
	if [[ $behaviour == *"[inhibit-charge"* ]]; then
		warn "charging is inhibited: echo auto > $ps/BAT0/charge_behaviour"
	elif [[ $start =~ ^[0-9]+$ && $capacity =~ ^[0-9]+$ ]] && ((capacity >= start)); then
		warn "charge thresholds hold the battery: it only charges below $start% (stops at $stop%)."
		warn "to charge to 100% once: tlp fullcharge BAT0 (or change START/STOP_CHARGE_THRESH_BAT0)"
	else
		warn "AC is online but BAT0 is '$status' with no threshold reason: check dmesg (battery, ucsi, EC), the charger and the cable"
		return 1
	fi
}

# cmd_verify: check the running kernel after rebooting into it (read-only)
cmd_verify() {
	CURRENT_STEP=verify
	require_args 0 verify
	local running module problems=0
	local -a modules
	running=$(uname -r)
	info "Running kernel: $running"
	[[ $running == *"-$NAME" ]] || die "not running the -$NAME kernel: reboot into it first"
	read -ra modules <<<"$VERIFY_MODULES"
	for module in "${modules[@]}"; do
		if [[ -d /sys/module/$module ]]; then
			info "module $module: loaded"
		elif [[ $module == amd_pmc ]] && ! amd_pmc_device_present; then
			info "module amd_pmc: skipped (no AMD PMC ACPI device: firmware uses S3 deep sleep)"
		else
			warn "module $module: not loaded"
			problems=$((problems + 1))
		fi
	done
	local tainted
	tainted=$(sysfs_read /proc/sys/kernel/tainted)
	[[ $tainted == 0 ]] || warn "kernel is tainted ($tainted): see dmesg"
	if [[ $VERIFY_BATTERY == yes ]]; then
		verify_charging || problems=$((problems + 1))
	fi
	((problems == 0)) || die "verify found $problems problem(s)"
	info "Verify OK"
}

# cmd_status: sources, configs, builds, installed kernels and GRUB's default at a glance
cmd_status() {
	CURRENT_STEP=status
	require_args 0 status
	local running top release marks stage
	running=$(uname -r)
	top=$(grub_top_level_release)
	info "Name: -$NAME (next release: $(expected_release))"
	info "Sources: $SRC_DIR -> $(readlink -f -- "$SRC_DIR")"
	if [[ -f $PERSONAL_CFG ]]; then
		info "personal.config: $(sed -n 's/^# \(Linux\/x86 .*\) Kernel Configuration$/\1/p' "$PERSONAL_CFG")"
	else
		warn "$PERSONAL_CFG missing: run '$PROG init' as root"
	fi
	[[ ! -f $DEFAULT_ORIGIN ]] || info "default.config: from $(<"$DEFAULT_ORIGIN")"
	check_default_origin
	info "Backups: $(list_backups | wc -l) of $KEEP_BACKUPS (newest: $(list_backups | head -1))"
	stage=$(work_dir "$(id -un)")/stage/release
	if [[ -r $stage ]]; then
		info "Built and waiting for install: $(<"$stage")"
	fi
	info "Running: $running"
	info "Installed personal kernels:"
	while read -r release; do
		marks=""
		[[ $release != "$running" ]] || marks+=" [running]"
		[[ $release != "$top" ]] || marks+=" [default]"
		[[ -f /boot/vmlinuz-$release ]] || marks+=" [missing in /boot]"
		echo "    $release$marks"
	done < <(registered_releases)
	[[ -n $top ]] || info "GRUB_TOP_LEVEL not set: GRUB boots its own first entry"
}
