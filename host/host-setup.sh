#!/bin/sh
# Self-contained host prep for the daemonless Sylve container. Run as root:
#
#   podman run --rm ghcr.io/daemonless/sylve:nightly host-setup > setup.sh
#   sh setup.sh          # confirms each step; add -y to auto-confirm
#   sh setup.sh --undo   # reverse it (removes the hook + devfs ruleset)
#
# Loads the kernel modules, devfs ruleset, ZFS dataset, and OCI hook that let
# Sylve manage bhyve/jails/ZFS from inside its jail. Idempotent -- already
# configured steps are detected and skipped. Override the ZFS dataset with
# SYLVE_DATASET=tank/sylve.
set -eu

# --- preflight: this touches kernel modules, /boot/loader.conf, devfs, and ZFS,
#     so it needs root on a FreeBSD 15+ host. Fail early and clearly otherwise. ---
if [ "$(id -u)" -ne 0 ]; then
	echo "sylve host-setup: must run as root (it edits loader.conf, devfs, ZFS, ...)." >&2
	exit 1
fi
if [ "$(uname -s)" != "FreeBSD" ]; then
	echo "sylve host-setup: FreeBSD only -- this host is $(uname -s)." >&2
	exit 1
fi
case "$(uname -r)" in
	1[5-9].*|[2-9][0-9].*) ;;   # 15.x and up
	*) echo "sylve host-setup: warning -- built for FreeBSD 15+, this host is $(uname -r);" >&2
	   echo "                  the module set (netlink, if_wg, ...) and behavior may differ." >&2 ;;
esac
for _t in podman ocijail podman-compose; do
	command -v "$_t" >/dev/null 2>&1 || echo "sylve host-setup: note -- '$_t' not found; it's needed to run Sylve." >&2
done

# ZFS dataset. Default zroot/sylve, but don't assume a zroot pool exists: if
# SYLVE_DATASET wasn't set and there's no zroot pool but exactly one other pool,
# use that. Step 4 validates the pool actually exists and errors clearly if not.
DATASET="${SYLVE_DATASET:-zroot/sylve}"
if [ -z "${SYLVE_DATASET:-}" ] && ! zpool list zroot >/dev/null 2>&1; then
	_pools="$(zpool list -H -o name 2>/dev/null)"
	[ "$(printf '%s' "$_pools" | grep -c .)" = "1" ] && DATASET="${_pools}/sylve"
fi
RULESET_NUM="${SYLVE_DEVFS_RULESET:-10}"
RULESET_NAME="devfsrules_jail_sylve=${RULESET_NUM}"
HOOKS_D=/usr/local/share/containers/oci/hooks.d
CONF_D=/usr/local/etc/containers/containers.conf.d
LIBEXEC=/usr/local/libexec/sylve
MODULES="vmm if_bridge cryptodev if_epair nullfs netlink nlsysevent nmdm pf pflog if_wg linux linux64 pty linprocfs linsysfs ctl"
SEP="------------------------------------------------------------"

# -y / --yes (or SYLVE_YES=1) runs every step without prompting.
# --undo reverses the setup: removes Sylve's hook + devfs ruleset. It leaves
# shared settings (kernel modules, pf/podman, racct) and the ZFS dataset alone.
YES=0; UNDO=0
for a in "$@"; do case "$a" in -y|--yes) YES=1 ;; --undo|--uninstall) UNDO=1 ;; esac; done
[ "${SYLVE_YES:-0}" = "1" ] && YES=1

TOTAL=5
ALREADY_MSG="Already configured -- nothing to do."
if [ "$UNDO" -eq 1 ]; then TOTAL=2; ALREADY_MSG="Already removed -- nothing to do."; fi

add_line() {
	grep -q "^$(printf '%s' "$2" | cut -d= -f1)=" "$1" 2>/dev/null || printf '%s\n' "$2" >> "$1"
}

# already <n> <title> -- the step is already satisfied; note it and move on.
already() {
	echo >&2
	echo "  Step $1 of $TOTAL:  $2" >&2
	echo "    $ALREADY_MSG" >&2
}

# step <n> <title> <detail> -- prints the pending change and, unless -y, asks on
# the terminal. Returns 0 to run the step, 1 to skip. Reads /dev/tty so it works
# even when the script is piped to sh.
step() {
	echo >&2
	echo "  Step $1 of $TOTAL:  $2" >&2
	echo "    $3" >&2
	[ "$YES" -eq 1 ] && return 0
	printf "    Run this step? [Y/n] " >&2
	if ! read ans < /dev/tty 2>/dev/null; then
		echo >&2
		echo "  No terminal for prompts. Re-run with -y to run all steps." >&2
		exit 1
	fi
	case "$ans" in [Nn]*) echo "    Skipped." >&2; return 1 ;; esac
	return 0
}

# --------------------------------------------------------------------------
# Undo mode -- remove Sylve's host footprint (hook + devfs ruleset). Shared
# settings (modules, pf/podman, racct) and the ZFS dataset are left alone.
# --------------------------------------------------------------------------
if [ "$UNDO" -eq 1 ]; then
	echo >&2
	echo "  $SEP" >&2
	echo "   Sylve host teardown (undo)" >&2
	echo "  $SEP" >&2
	echo "   Removes Sylve's host footprint: the OCI hook and the devfs" >&2
	echo "   ruleset. Kernel modules, pf/podman, and your ZFS dataset are" >&2
	echo "   left alone. Each step asks (Enter/y = do, n = skip, -y = all)." >&2

	# Undo 1: OCI hook + drop-in
	if [ ! -e "$LIBEXEC/sylve-hook.sh" ] && [ ! -e "$HOOKS_D/sylve-hook.json" ] && [ ! -e "$CONF_D/sylve-hooks.conf" ]; then
		already 1 "OCI hook"
	elif step 1 "OCI hook" "Remove the hook and its podman drop-in:
      ${LIBEXEC}/sylve-hook.sh
      ${HOOKS_D}/sylve-hook.json
      ${CONF_D}/sylve-hooks.conf"; then
		rm -f "$LIBEXEC/sylve-hook.sh" "$HOOKS_D/sylve-hook.json" "$CONF_D/sylve-hooks.conf"
		rmdir "$LIBEXEC" 2>/dev/null || true
		echo "    Done." >&2
	fi

	# Undo 2: devfs ruleset
	if ! grep -q "\[${RULESET_NAME}\]" /etc/devfs.rules 2>/dev/null; then
		already 2 "Device access"
	elif step 2 "Device access" "Remove devfs ruleset ${RULESET_NAME} from /etc/devfs.rules."; then
		awk -v r="[${RULESET_NAME}]" 'BEGIN{skip=0} $0==r{skip=1;next} skip&&/^\[/{skip=0} !skip' \
			/etc/devfs.rules > /etc/devfs.rules.new && mv /etc/devfs.rules.new /etc/devfs.rules
		service devfs restart >/dev/null 2>&1 || true
		echo "    Done." >&2
	fi

	echo >&2
	echo "  $SEP" >&2
	echo "   Teardown complete." >&2
	echo "  $SEP" >&2
	echo "   Left alone (shared, may be used by other containers):" >&2
	echo "     kernel modules + racct in /boot/loader.conf; pf/podman in /etc/rc.conf" >&2
	echo >&2
	echo "   Your ZFS dataset was NOT touched. To delete it and its data:" >&2
	echo "     zfs destroy -r ${DATASET}" >&2
	echo >&2
	exit 0
fi

echo >&2
echo "  $SEP" >&2
echo "   Sylve host setup" >&2
echo "  $SEP" >&2
echo "   One-time prep so Sylve can manage bhyve, jails, and ZFS" >&2
echo "   from inside its jail. Already-configured steps are skipped;" >&2
echo "   the rest ask before running (Enter/y = run, n = skip, -y = all)." >&2

# 1. kernel modules -- load now (no reboot for these) and persist in loader.conf.
#    "missing" = not loaded, or not yet in /boot/loader.conf.
mod_todo=""
for m in $MODULES; do
	grep -q "^${m}_load=" /boot/loader.conf 2>/dev/null || mod_todo="$mod_todo $m"
done
grep -q "^kern.racct.enable=" /boot/loader.conf 2>/dev/null || mod_todo="$mod_todo kern.racct.enable"
if [ -z "$mod_todo" ]; then
	already 1 "Kernel modules"
elif step 1 "Kernel modules" "Load into the kernel and persist in /boot/loader.conf:
     $mod_todo"; then
	for m in $MODULES; do
		kldstat -q -n "$m" 2>/dev/null || kldload "$m" 2>/dev/null || true
		add_line /boot/loader.conf "${m}_load=\"YES\""
	done
	add_line /boot/loader.conf 'kern.racct.enable="1"'
	echo "    Done." >&2
fi

# 2. rc.conf -- pf, and the podman service that auto-starts restart=always
#    containers after a reboot.
rc_todo=""
grep -q "^pf_enable=" /etc/rc.conf 2>/dev/null || rc_todo="$rc_todo pf_enable=\"YES\""
grep -q "^podman_enable=" /etc/rc.conf 2>/dev/null || rc_todo="$rc_todo podman_enable=\"YES\""
if [ -z "$rc_todo" ]; then
	already 2 "System services"
elif step 2 "System services" "Add to /etc/rc.conf (podman auto-starts the container after a reboot):
     $rc_todo"; then
	add_line /etc/rc.conf 'pf_enable="YES"'
	add_line /etc/rc.conf 'podman_enable="YES"'
	service pf onestart >/dev/null 2>&1 || true
	echo "    Done." >&2
fi

# 3. devfs ruleset -- every device Sylve's init/features touch. Each missing
#    entry crash-loops a different init step: pf/pflog (firewall/libvirtd),
#    cam/ctl (iSCSI), vmm*/vmmctl (bhyve), nmdm* (VM consoles), da/ada/nda
#    (disks), tap*/bpf* (networking).
if grep -q "\[${RULESET_NAME}\]" /etc/devfs.rules 2>/dev/null; then
	already 3 "Device access"
elif step 3 "Device access" "Add devfs ruleset ${RULESET_NAME} to /etc/devfs.rules, exposing to the jail:
      pf pflog  vmm vmmctl vmm.io  cam/ctl  nmdm* tap* bpf*  da* ada* nda*"; then
	cat >> /etc/devfs.rules <<EOF

[${RULESET_NAME}]
add include \$devfsrules_hide_all
add include \$devfsrules_unhide_basic
add include \$devfsrules_unhide_login
add include \$devfsrules_jail
add include \$devfsrules_jail_vnet
add path pf unhide
add path pflog unhide
add path 'bpf*' unhide
add path 'vmmctl' unhide
add path 'vmm' unhide
add path 'vmm/*' unhide
add path 'vmm.io' unhide
add path 'vmm.io/*' unhide
add path 'nmdm*' unhide
add path 'tap*' unhide
add path cam unhide
add path 'cam/ctl' unhide
add path 'da*' unhide
add path 'ada*' unhide
add path 'nda*' unhide
EOF
	service devfs restart >/dev/null 2>&1 || true
	echo "    Done." >&2
fi

# 4. ZFS dataset for Sylve's data. Validate the pool exists first -- don't
#    assume zroot (or whatever SYLVE_DATASET names) is present.
_pool="${DATASET%%/*}"
if ! zpool list "$_pool" >/dev/null 2>&1; then
	echo >&2
	echo "  Step 4 of $TOTAL:  ZFS dataset" >&2
	echo "    ZFS pool '$_pool' does not exist on this host." >&2
	echo "    Pools available: $(zpool list -H -o name 2>/dev/null | tr '\n' ' ')" >&2
	echo "    Set SYLVE_DATASET=<pool>/sylve and re-run (use the same value in .env)." >&2
	exit 1
elif zfs list "$DATASET" >/dev/null 2>&1; then
	already 4 "ZFS dataset"
elif step 4 "ZFS dataset" "Create the dataset for Sylve's data:
      zfs create ${DATASET}"; then
	zfs create "$DATASET"
	echo "    Done." >&2
fi

# 5. OCI hook + the containers.conf.d drop-in that enables podman's hooks dir
#    (podman ships hooks_dir commented out, so hooks never fire otherwise).
#    Bump SYLVE_HOOK_VER whenever the embedded hook below changes: the installed
#    copy carries the marker, so a newer version replaces an old one instead of
#    being skipped by a bare existence check.
SYLVE_HOOK_VER=2
if grep -q "sylve-hook-ver: ${SYLVE_HOOK_VER}\$" "$LIBEXEC/sylve-hook.sh" 2>/dev/null \
   && [ -f "$HOOKS_D/sylve-hook.json" ] && [ -f "$CONF_D/sylve-hooks.conf" ]; then
	already 5 "OCI hook"
elif step 5 "OCI hook" "Install/refresh the createRuntime hook + hooks_dir drop-in:
      ${LIBEXEC}/sylve-hook.sh
      ${HOOKS_D}/sylve-hook.json
      ${CONF_D}/sylve-hooks.conf"; then
	mkdir -p "$LIBEXEC" "$HOOKS_D" "$CONF_D"

	cat > "$LIBEXEC/sylve-hook.sh" <<'SYLVE_HOOK_EOF'
#!/bin/sh
# sylve-hook-ver: 2
# OCI createRuntime hook for the daemonless Sylve container. Runs on the HOST
# right after the jail is created, before Sylve starts. Does the jail wiring
# ocijail annotations can't:
#   * applies the devfs ruleset to the jail's /dev (ocijail ignores the
#     org.freebsd.jail.devfs_ruleset annotation, so without this the jail has
#     no /dev/pf, /dev/vmm, /dev/cam/ctl and Sylve crash-loops at init)
#   * ZFS pool delegation (zfs jail)
#   * allow.vmm / allow.mount.* / enforce_statfs via jail(8)
#   * child-jail permissions so Sylve can create jails: children.max plus the
#     allow.* flags a child requests (a child can't exceed the parent's set)
set -e

state="$(cat)"

json_str() {
	printf '%s' "$state" | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed 's/.*"\([^"]*\)"$/\1/'
}

jail_name="$(json_str id)"
if [ -z "$jail_name" ]; then
	echo "sylve-hook: could not extract jail name from OCI state" >&2
	exit 1
fi

dataset="$(json_str 'io.daemonless.sylve.dataset')"
[ -z "$dataset" ] && dataset="zroot/sylve"

ruleset="$(json_str 'org.freebsd.jail.devfs_ruleset')"
[ -z "$ruleset" ] && ruleset=10
jpath="$(jls -j "$jail_name" path 2>/dev/null)"
if [ -n "$jpath" ] && [ -d "$jpath/dev" ]; then
	devfs -m "$jpath/dev" ruleset "$ruleset"
	devfs -m "$jpath/dev" rule applyset
fi

jail -m name="$jail_name" allow.vmm=1 enforce_statfs=1 allow.mount=1
for fs in devfs fdescfs linprocfs linsysfs tmpfs zfs; do
	jail -m name="$jail_name" "allow.mount.$fs=1"
done

# Child-jail creation: Sylve builds guest jails as children of its own jail.
# children.max must be >0, and every allow.* a child requests must already be
# set on the parent (a child can't hold a permission the parent lacks).
jail -m name="$jail_name" children.max=100 \
	allow.socket_af=1 allow.sysvipc=1 allow.raw_sockets=1 \
	allow.reserved_ports=1 allow.set_hostname=1 allow.suser=1 allow.chflags=1

zfs set jailed=on "$dataset"
zfs jail "$jail_name" "$dataset"
SYLVE_HOOK_EOF
	chmod 0755 "$LIBEXEC/sylve-hook.sh"

	cat > "$HOOKS_D/sylve-hook.json" <<'SYLVE_JSON_EOF'
{
    "version": "1.0.0",
    "hook": {
        "path": "/usr/local/libexec/sylve/sylve-hook.sh",
        "timeout": 30
    },
    "when": {
        "annotations": {
            "io.daemonless.sylve.autowire": "true"
        }
    },
    "stages": ["createRuntime"]
}
SYLVE_JSON_EOF

	cat > "$CONF_D/sylve-hooks.conf" <<EOF
[engine]
hooks_dir = ["${HOOKS_D}"]
EOF
	echo "    Done." >&2
fi

echo >&2
echo "  $SEP" >&2
echo "   Host setup complete." >&2
echo "  $SEP" >&2
if [ "$(sysctl -n kern.racct.enable 2>/dev/null || echo 0)" != "1" ]; then
	echo "   Reboot first -- kern.racct is off and Sylve requires it:" >&2
	echo "       reboot" >&2
	echo >&2
fi
echo "   Next, create your deployment files, edit .env, and start Sylve:" >&2
echo >&2
echo "       podman run --rm -v \"\$PWD:/out\" ghcr.io/daemonless/sylve:nightly init" >&2
echo "       vi .env      # SYLVE_HOSTNAME, SYLVE_DATA_LOCATION; SYLVE_DATASET=${DATASET}" >&2
echo "       podman compose up -d" >&2
echo >&2
