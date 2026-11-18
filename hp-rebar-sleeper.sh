#!/bin/bash
# hp-rebar-sleeper - give every Intel Arc GPU in this machine the largest resizable
# BAR it advertises, on systems whose firmware publishes no MMIO window above
# 4 GiB.
#
# Why this is needed: pci_resize_resource() only reprograms the bridge directly
# above the device.  Arc cards put a PCIe switch between the GPU and its root
# port, so growing BAR2 at runtime fails with -ENOSPC.  Setting the ReBAR size
# first and then forcing a full re-enumeration makes Linux size every bridge
# window in the chain, drawing from the >4 GiB root-bus window that pci=nocrs
# opens up.
#
# Required on the kernel command line:
#   pci=nocrs                   so the root bus has address space above 4 GiB
#   modprobe.blacklist=<mods>   so no driver binds before this runs.
#                               Run "hp-rebar-sleeper.sh check" to see which modules.
#
# Usage:
#   hp-rebar-sleeper.sh check     read-only.  Print what would be done and stop.
#   hp-rebar-sleeper.sh           do it.  This is what the systemd unit runs.
#
# Optional /etc/hp-rebar-sleeper.conf:
#   SKIP="0000:0a:00.0"    leave these devices alone
#   MAX_SIZE_IDX=13        never ask for more than 2^13 MiB (8 GiB)

set -u

REBAR_CTL=428                 # ReBAR capability @0x420, entry-0 Control at +0x08
CONF=/etc/hp-rebar-sleeper.conf

SKIP=""
MAX_SIZE_IDX=63

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

MODE=${1:-apply}
case "$MODE" in
    check|apply) ;;
    *) echo "usage: ${0##*/} [check]" >&2; exit 2 ;;
esac

log() {
    if [ "$MODE" = check ]; then
        printf '%s\n' "$*"
    else
        logger -t hp-rebar-sleeper -- "$*"
        printf 'hp-rebar-sleeper: %s\n' "$*"
    fi
}

# ---------------------------------------------------------------- helpers ---

# Which driver claims this PCI device ID.  Alchemist (DG2) is i915, Battlemage
# (BMG) is xe.  Anything else we do not recognise is reported, not guessed.
module_for() {
    case "$1" in
        56[0-9a-f][0-9a-f]|4f8[0-9a-f]) echo i915 ;;
        e2[0-9a-f][0-9a-f])             echo xe   ;;
        *)                              echo ""   ;;
    esac
}

# The root port above a device: the first component of its sysfs path below
# the host bridge.  A device sitting directly on the root bus returns itself.
rootport_of() {
    local p
    p=$(readlink -f "/sys/bus/pci/devices/$1") || return 1
    p=${p#/sys/devices/}
    p=${p#pci*/}
    printf '%s\n' "${p%%/*}"
}

# Highest set bit of a number, or -1 if none.
highest_bit() {
    local v=$1 b i=-1
    for b in $(seq 0 31); do
        [ $(( (v >> b) & 1 )) -eq 1 ] && i=$b
    done
    printf '%s\n' "$i"
}

# 2^idx MiB rendered for humans.
human_size() {
    local idx=$1
    if [ "$idx" -ge 10 ]; then
        printf '%s GiB\n' $(( 1 << (idx - 10) ))
    else
        printf '%s MiB\n' $(( 1 << idx ))
    fi
}

bar2_of() { sed -n 3p "/sys/bus/pci/devices/$1/resource" 2>/dev/null; }

wait_for_dev() {
    local i
    for i in $(seq 1 50); do
        [ -r "/sys/bus/pci/devices/$1/resource" ] && return 0
        sleep 0.1
    done
    return 1
}

# The graphics modules named in modprobe.blacklist= on the kernel command line.
# Only xe and i915 are ours to load; anything else there was blacklisted by the
# user for their own reasons and must be left alone.
blacklisted_modules() {
    local list m
    list=$(sed -n 's/.*\bmodprobe\.blacklist=\([^ ]*\).*/\1/p' /proc/cmdline)
    for m in $(printf '%s' "$list" | tr ',' ' '); do
        case "$m" in xe|i915) printf '%s\n' "$m" ;; esac
    done
}

in_list() {
    local needle=$1 item
    shift
    for item in $@; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

# ------------------------------------------------------------- discovery ---

BDFS=""       # devices we will resize
PORTS=""      # their root ports, de-duplicated
MODULES=""    # every module seen, de-duplicated; these get loaded afterwards
NEEDBLACK=""  # modules that actually have to be kept out of the way at boot
BLOCKED=""    # check mode only: devices whose driver is bound right now
declare -A CUR TGT PORT MOD

for path in /sys/bus/pci/devices/*; do
    bdf=${path##*/}

    [ -r "$path/vendor" ] || continue
    [ "$(cat "$path/vendor")" = "0x8086" ] || continue
    [ "$(cat "$path/class" 2>/dev/null)" = "0x030000" ] || continue
    [ -r "$path/resource2_resize" ] || continue        # no ReBAR, not for us

    did=$(cat "$path/device"); did=${did#0x}
    mod=$(module_for "$did")

    if [ -z "$mod" ]; then
        log "$bdf: Intel GPU $did is not a device this script knows. Skipping."
        continue
    fi

    # Remember every module we saw, even for devices we skip, so that "check"
    # can print a complete modprobe.blacklist= line.
    in_list "$mod" "$MODULES" || MODULES="$MODULES $mod"

    if in_list "$bdf" "$SKIP"; then
        log "$bdf: listed in SKIP. Leaving alone."
        continue
    fi

    sup=$(cat "$path/resource2_resize")
    tgt=$(highest_bit "$((0x$sup))")
    if [ "$tgt" -lt 0 ]; then
        log "$bdf: advertises no resizable BAR sizes. Skipping."
        continue
    fi
    [ "$tgt" -gt "$MAX_SIZE_IDX" ] && tgt=$MAX_SIZE_IDX

    ctl=$(setpci -s "$bdf" "$REBAR_CTL.l" 2>/dev/null) || {
        log "$bdf: cannot read the ReBAR control register. Are you root? Skipping."
        continue
    }
    cur=$(( (0x$ctl >> 8) & 0x3F ))

    rp=$(rootport_of "$bdf") || { log "$bdf: cannot find its root port. Skipping."; continue; }
    if [ "$rp" = "$bdf" ]; then
        log "$bdf: sits directly on the root bus, no bridge to reprogram. Skipping."
        continue
    fi

    if [ "$cur" -eq "$tgt" ]; then
        log "$bdf: BAR is already $(human_size "$tgt"). Nothing to do."
        continue
    fi

    # Clearing COMMAND and removing a root port under a live driver deadlocks
    # in the driver's remove path while device_lock is held, which wedges the
    # machine.  In "check" that is the normal state of a running desktop and
    # only worth noting; in "apply" it means modprobe.blacklist= is missing and
    # we must not touch the device.
    if [ -e "$path/driver" ]; then
        drv=$(basename "$(readlink -f "$path/driver")")
        if [ "$MODE" = check ]; then
            log "$bdf: $(human_size "$cur") -> $(human_size "$tgt")  (driver $mod, root port $rp)"
            log "$bdf: '$drv' is bound right now, so this needs a reboot with the blacklist set."
            BLOCKED="$BLOCKED $bdf"
            in_list "$mod" "$NEEDBLACK" || NEEDBLACK="$NEEDBLACK $mod"
            in_list "$rp" "$PORTS" || PORTS="$PORTS $rp"
        else
            log "$bdf: driver '$drv' is already bound and the BAR is not yet $(human_size "$tgt")."
            log "$bdf: resizing now would hang the machine. Check modprobe.blacklist=$mod"
        fi
        continue
    fi

    BDFS="$BDFS $bdf"
    CUR[$bdf]=$cur
    TGT[$bdf]=$tgt
    PORT[$bdf]=$rp
    MOD[$bdf]=$mod
    in_list "$rp" "$PORTS" || PORTS="$PORTS $rp"
    in_list "$mod" "$NEEDBLACK" || NEEDBLACK="$NEEDBLACK $mod"

    log "$bdf: $(human_size "$cur") -> $(human_size "$tgt")  (driver $mod, root port $rp)"
done

MODULES=${MODULES# }
NEEDBLACK=${NEEDBLACK# }
BDFS=${BDFS# }
PORTS=${PORTS# }

# ----------------------------------------------------------------- check ---

if [ "$MODE" = check ]; then
    echo
    if [ -z "$MODULES" ]; then
        echo "No Intel Arc GPU with a resizable BAR was found."
        exit 0
    fi
    if [ -z "$BDFS" ] && [ -z "$BLOCKED" ]; then
        echo "Nothing needs resizing on this machine."
        echo "Put pci=nocrs on your kernel command line and you are done."
        echo "You do not need modprobe.blacklist= and you do not need the service."
    else
        echo "Put this on your kernel command line:"
        echo
        echo "    pci=nocrs modprobe.blacklist=$(echo "$NEEDBLACK" | tr ' ' ',')"
        echo
        echo "Or, if you expect to swap cards around, this works for any Arc card"
        echo "and never has to be edited again:"
        echo
        echo "    pci=nocrs modprobe.blacklist=xe,i915"
        echo
        echo "Would resize:$BDFS$BLOCKED"
        echo "Would remove and rescan:$PORTS"
        [ -n "$BLOCKED" ] && echo "Install the service, then reboot."
    fi
    echo
    grep -q 'pci=nocrs' /proc/cmdline \
        || echo "WARNING: pci=nocrs is not on the current kernel command line."
    exit 0
fi

# ----------------------------------------------------------------- apply ---

# Load the drivers.  As well as the ones our own devices need, load anything
# the kernel command line told the kernel to hold back on our behalf: that way
# "modprobe.blacklist=xe,i915" is safe to leave in place permanently, and
# swapping cards needs no change to the boot loader.
finish() {
    local m
    for m in $(blacklisted_modules); do
        in_list "$m" "$MODULES" || MODULES="$MODULES $m"
    done
    for m in $MODULES; do
        log "loading $m"
        modprobe "$m" || log "modprobe $m failed"
    done
    exit 0
}

[ -n "$BDFS" ] || { log "nothing to do"; finish; }

grep -q 'pci=nocrs' /proc/cmdline \
    || log "WARNING: pci=nocrs is not set; the resize will probably not fit"

for bdf in $BDFS; do
    setpci -s "$bdf" COMMAND=0000 || { log "$bdf: failed to clear COMMAND"; finish; }
    ctl=$(setpci -s "$bdf" "$REBAR_CTL.l")
    new=$(printf '%08x' $(( (0x$ctl & ~0x3F00) | (TGT[$bdf] << 8) )))
    setpci -s "$bdf" "$REBAR_CTL.l=$new" || { log "$bdf: failed to write ReBAR control"; finish; }
    log "$bdf: ReBAR control 0x$ctl -> 0x$new"
done

# At boot the Plymouth splash may be drawing on simpledrm, which scans out the
# UEFI GOP framebuffer inside the old BAR2.  Let it go before that memory moves.
# Cosmetic only: the splash ends a few seconds early.
if command -v plymouth >/dev/null 2>&1 && plymouth --ping >/dev/null 2>&1; then
    log "asking plymouth to quit before the framebuffer moves"
    plymouth quit >/dev/null 2>&1 || log "plymouth quit failed (continuing)"
fi

SFB=/sys/bus/platform/drivers/simple-framebuffer
if [ -e "$SFB/simple-framebuffer.0" ]; then
    log "unbinding simpledrm from simple-framebuffer.0"
    echo simple-framebuffer.0 > "$SFB/unbind" 2>/dev/null \
        || log "simpledrm unbind failed (continuing)"
fi

# Do NOT re-enable memory decode here: with the larger size the old base address
# is truncated to 0, so the BAR would overlap DRAM.  The rescan reprograms it and
# the driver enables decode via pci_enable_device().
for rp in $PORTS; do
    log "removing $rp subtree"
    echo 1 > "/sys/bus/pci/devices/$rp/remove" || log "$rp: remove failed"
done

log "rescanning"
echo 1 > /sys/bus/pci/rescan || { log "rescan failed"; finish; }

# ------------------------------------------------------- verify, roll back ---

FAILED=""
FAILPORTS=""

for bdf in $BDFS; do
    if ! wait_for_dev "$bdf"; then
        log "$bdf: did not reappear after the rescan"
        continue
    fi
    read -r s e _ < <(bar2_of "$bdf")
    if [ "$s" = "0x0000000000000000" ] && [ "$e" = "0x0000000000000000" ]; then
        log "$bdf: BAR2 unassigned. $(human_size "${TGT[$bdf]}") does not fit here."
        FAILED="$FAILED $bdf"
        in_list "${PORT[$bdf]}" "$FAILPORTS" || FAILPORTS="$FAILPORTS ${PORT[$bdf]}"
    else
        log "$bdf: BAR2 $s-$e ($(( (e - s + 1) / 1048576 )) MiB)"
    fi
done

if [ -n "$FAILED" ]; then
    for bdf in $FAILED; do
        log "$bdf: rolling back to $(human_size "${CUR[$bdf]}")"
        setpci -s "$bdf" COMMAND=0000 2>/dev/null
        ctl=$(setpci -s "$bdf" "$REBAR_CTL.l" 2>/dev/null) || continue
        old=$(printf '%08x' $(( (0x$ctl & ~0x3F00) | (CUR[$bdf] << 8) )))
        setpci -s "$bdf" "$REBAR_CTL.l=$old" || log "$bdf: could not restore ReBAR control"
    done

    for rp in $FAILPORTS; do
        echo 1 > "/sys/bus/pci/devices/$rp/remove" 2>/dev/null
    done
    echo 1 > /sys/bus/pci/rescan 2>/dev/null

    for bdf in $FAILED; do
        if wait_for_dev "$bdf"; then
            read -r s e _ < <(bar2_of "$bdf")
            log "$bdf: BAR2 after rollback: $s-$e ($(( (e - s + 1) / 1048576 )) MiB)"
        else
            log "$bdf: did not reappear after the rollback"
        fi
    done

    log "a smaller BAR would fit: set MAX_SIZE_IDX in $CONF and reboot"
fi

finish
