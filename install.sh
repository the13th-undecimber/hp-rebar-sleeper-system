#!/bin/bash
# install.sh - set up hp-rebar-sleeper on this machine.
#
#   sudo ./install.sh              install, after showing what it will do
#   sudo ./install.sh --dry-run    show what it would do and change nothing
#   sudo ./install.sh --uninstall  undo everything this installed
#
# Options:
#   --yes                  do not ask for confirmation
#   --blacklist=xe,i915    override which drivers are held back at boot
#
# Everything this touches can be undone with --uninstall.  Nothing is written
# to the BIOS or to the hardware.

set -u

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SCRIPT_NAME=hp-rebar-sleeper.sh
UNIT_NAME=hp-rebar-sleeper.service
CONF=/etc/hp-rebar-sleeper.conf

SBIN=/usr/local/sbin
UNIT_DIR=/etc/systemd/system
GRUB_DIR=/etc/default/grub.d
GRUB_FILE=$GRUB_DIR/hp-rebar-sleeper.cfg

DRY=0
YES=0
UNINSTALL=0
BLACKLIST=""

for arg in "$@"; do
    case "$arg" in
        --dry-run)      DRY=1 ;;
        --yes|-y)       YES=1 ;;
        --uninstall)    UNINSTALL=1 ;;
        --blacklist=*)  BLACKLIST=${arg#--blacklist=} ;;
        -h|--help)      awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"
                        exit 0 ;;
        *)              echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

say()  { printf '%s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
run()  { if [ "$DRY" = 1 ]; then printf '  would run: %s\n' "$*"; else "$@"; fi; }

[ "$(id -u)" = 0 ] || die "run this with sudo"

# --------------------------------------------------------------- helpers ---

# Ubuntu and Debian patch grub-mkconfig to source /etc/default/grub.d/*.cfg.
# Where that is true we can add and remove our kernel arguments by creating and
# deleting one file, and /etc/default/grub is never touched.
# The path is written as ${sysconfdir}/default/grub.d inside the script, not
# spelled out, so match the tail of it rather than the whole path.  /etc/grub.d
# appears there too and is a different directory, hence "default/".
grub_dropin_supported() {
    local mk found
    found=$(command -v grub-mkconfig 2>/dev/null || true)
    for mk in "$found" /usr/sbin/grub-mkconfig /sbin/grub-mkconfig /usr/bin/grub-mkconfig; do
        [ -n "$mk" ] || continue
        [ -r "$mk" ] || continue
        grep -q 'default/grub\.d' "$mk" && return 0
    done
    return 1
}

regenerate_grub() {
    if command -v update-grub >/dev/null 2>&1; then
        run update-grub
    elif command -v grub-mkconfig >/dev/null 2>&1; then
        if [ -d /boot/grub ]; then
            run grub-mkconfig -o /boot/grub/grub.cfg
        else
            run grub-mkconfig -o /boot/grub2/grub.cfg
        fi
    else
        say "WARNING: no update-grub or grub-mkconfig found. Regenerate your"
        say "         boot loader configuration by hand."
    fi
}

# An Intel GPU on the processor itself.  Holding i915 back on such a machine
# also holds back the display it is driving, so there we blacklist only what is
# strictly needed rather than both drivers.
has_intel_igpu() {
    local d=/sys/bus/pci/devices/0000:00:02.0
    [ -r "$d/vendor" ] || return 1
    [ "$(cat "$d/vendor")" = "0x8086" ] || return 1
    [ "$(cat "$d/class" 2>/dev/null)" = "0x030000" ] || return 1
    return 0
}

# ------------------------------------------------------------- uninstall ---

if [ "$UNINSTALL" = 1 ]; then
    say "Removing hp-rebar-sleeper."
    say
    if systemctl list-unit-files "$UNIT_NAME" >/dev/null 2>&1; then
        run systemctl disable --now "$UNIT_NAME"
    fi
    [ -e "$UNIT_DIR/$UNIT_NAME" ] && run rm -f "$UNIT_DIR/$UNIT_NAME"
    run systemctl daemon-reload
    [ -e "$SBIN/$SCRIPT_NAME" ] && run rm -f "$SBIN/$SCRIPT_NAME"
    if [ -e "$GRUB_FILE" ]; then
        run rm -f "$GRUB_FILE"
        regenerate_grub
    else
        say "  $GRUB_FILE is not there."
        say "  If you added pci=nocrs to /etc/default/grub by hand, remove it there."
    fi
    say
    [ -e "$CONF" ] && say "Left in place: $CONF (you wrote it, so it is yours to delete)."
    say "Done. Reboot to go back to how the machine was."
    exit 0
fi

# --------------------------------------------------------------- install ---

[ -r "$SELF_DIR/$SCRIPT_NAME" ] || die "$SCRIPT_NAME is not next to this installer"
[ -r "$SELF_DIR/$UNIT_NAME" ]   || die "$UNIT_NAME is not next to this installer"

say "Looking at this machine."
say
bash "$SELF_DIR/$SCRIPT_NAME" check || die "the check failed"
say

if [ -z "$BLACKLIST" ]; then
    needed=$(bash "$SELF_DIR/$SCRIPT_NAME" modules | tr '\n' ',' | sed 's/,$//')
    if has_intel_igpu; then
        BLACKLIST=$needed
        igpu_note=1
    else
        # No integrated GPU to strand, so hold back both drivers.  That way
        # swapping cards around later needs no change here.
        BLACKLIST=xe,i915
        igpu_note=0
    fi
else
    igpu_note=0
fi

CMDLINE="pci=nocrs"
[ -n "$BLACKLIST" ] && CMDLINE="$CMDLINE modprobe.blacklist=$BLACKLIST"

say "Plan:"
say "  install  $SBIN/$SCRIPT_NAME"
say "  install  $UNIT_DIR/$UNIT_NAME, and enable it"
if grub_dropin_supported; then
    say "  create   $GRUB_FILE, adding:  $CMDLINE"
    say "  run      update-grub"
else
    say "  NOTE     this system does not read $GRUB_DIR, so the kernel"
    say "           arguments will have to be added by hand (shown at the end)"
fi
say
say "  /etc/default/grub is not modified.  Nothing is written to the BIOS."
say "  Undo all of it with: sudo $0 --uninstall"
say
if [ "$igpu_note" = 1 ]; then
    say "  This machine has an Intel GPU on the processor, so only the drivers"
    say "  actually needed are held back.  Blacklisting i915 here would also"
    say "  hold back the integrated display."
    say
fi

if [ "$DRY" = 1 ]; then
    say "--dry-run: stopping here."
    exit 0
fi

if [ "$YES" != 1 ]; then
    printf 'Go ahead? [y/N] '
    read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) say "Nothing was changed."; exit 0 ;; esac
    say
fi

run install -m 0755 "$SELF_DIR/$SCRIPT_NAME" "$SBIN/$SCRIPT_NAME"
run install -m 0644 "$SELF_DIR/$UNIT_NAME"   "$UNIT_DIR/$UNIT_NAME"
run systemctl daemon-reload
run systemctl enable "$UNIT_NAME"

if grub_dropin_supported; then
    run mkdir -p "$GRUB_DIR"
    if [ "$DRY" = 1 ]; then
        printf '  would write: %s\n' "$GRUB_FILE"
    else
        cat > "$GRUB_FILE" <<EOF
# Written by hp-rebar-sleeper's install.sh.
# Delete this file and run update-grub to undo it.
GRUB_CMDLINE_LINUX_DEFAULT="\$GRUB_CMDLINE_LINUX_DEFAULT $CMDLINE"
EOF
    fi
    regenerate_grub
fi

say
say "Installed."
say
if grub_dropin_supported; then
    say "Reboot, then check it worked with:"
else
    say "Add this to GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub:"
    say
    say "    $CMDLINE"
    say
    say "then run update-grub, reboot, and check it worked with:"
fi
say
say "    journalctl -b -t hp-rebar-sleeper"
say
say "If the machine does not come up, hold Shift at boot, press e, and add"
say "    systemd.mask=$UNIT_NAME"
say "to the kernel line.  That starts the machine with this turned off."
