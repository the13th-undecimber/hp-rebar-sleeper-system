# hp-rebar-sleeper-system

Resizable BAR / Large BAR for Intel Arc on HP systems whose BIOS has no
Above 4G Decoding option. Linux, no BIOS modification.

- [Read this first](#read-this-first)
- [Does your BIOS have Above 4G Decoding?](#does-your-bios-have-above-4g-decoding)
- [Enabling a large BAR](#enabling-a-large-bar)
- [Arc Pro B60](#arc-pro-b60)
- [Appendix: 36-bit machines](#appendix-36-bit-machines)
- [Related projects](#related-projects)
- [License and credits](#license-and-credits)

---

## Read this first

1. **HP machines only.** Everything here was worked out on HP workstations and
   one HP desktop. It may well apply elsewhere; nobody has checked.
2. **Linux only.** There is no Windows equivalent of this. See
   [related projects](#related-projects).
3. **Only the BAR itself is verified.** What is confirmed is that the card ends
   up with a large BAR and that software can then use it. That is all.
4. **Gaming performance was not measured.** Not once, on any machine. If you are
   here for frames per second, there are no numbers on this page.

Nothing here modifies your BIOS. There is no flashing, no `setup_var.efi`, no
modified firmware image. The change lives in the card's PCI configuration space,
a power cycle undoes it, and a boot-time service puts it back. To be rid of it
entirely, run the uninstaller and reboot.

---

## Does your BIOS have Above 4G Decoding?

Look for an option called **Above 4G Decoding**, **Memory Map IO above 4GB**, or
something similar.

- **It is there** → you do not need this project. Turn it on, then use
  [arc-rebar](https://github.com/RodBurlamaqui/Intel-ARC-Rebar), or, on a Dell
  Precision 5820,
  [precision-5820-arc-b60-large-bar](https://github.com/skipzx-lab/precision-5820-arc-b60-large-bar).
  Both are simpler than what follows.
- **It is not there at all** → this page is for you.

---

# Enabling a large BAR

## Install

Download these three files into **one folder**:

    install.sh
    hp-rebar-sleeper.sh
    hp-rebar-sleeper.service

Or clone the repository, which does the same thing:

    git clone https://github.com/the13th-undecimber/hp-rebar-sleeper-system
    cd hp-rebar-sleeper-system

Now open a terminal, go to the folder you put them in, and look at what is
there:

    cd ~/Downloads
    ls

All three names should be in that list. Your download folder is named in your
system's language, so it may not be called `Downloads` — use whatever yours is
called. If one of the files is missing, the installer stops and tells you which.

See what it would do. This changes nothing:

    sudo bash ./install.sh --dry-run

If the plan looks right, do it:

    sudo bash ./install.sh

Then reboot.

The installer looks at the cards actually fitted and works out the rest: which
device, which driver, which PCIe root port, and how large a BAR the card
advertises. It adds the kernel arguments through
`/etc/default/grub.d/hp-rebar-sleeper.cfg`, so `/etc/default/grub` is not
touched and nothing of yours is edited.

> **If you installed an earlier version of this by hand,** remove the arguments
> you added to `/etc/default/grub` first and run `update-grub`. Otherwise they
> will be there twice, and the uninstaller will not be able to remove them.

## Check it worked

    journalctl -b -t hp-rebar-sleeper

A successful boot looks like this:

    0000:03:00.0: 256 MiB -> 16 GiB (driver xe, root port 0000:00:01.0)
    0000:03:00.0: ReBAR control 0x00000822 -> 0x00000e22
    asking plymouth to quit before the framebuffer moves
    unbinding simpledrm from simple-framebuffer.0
    removing 0000:00:01.0 subtree
    rescanning
    0000:03:00.0: BAR2 0x0000000c00000000-0x0000000fffffffff (16384 MiB)
    loading xe
    loading i915

And the card agrees:

    $ sudo lspci -s 03:00.0 -vv | grep -E 'Region 2:|BAR 2'
      Region 2: Memory at c00000000 (64-bit, prefetchable) [size=16G]
        BAR 2: current size: 16GB, supported: 256MB 512MB 1GB 2GB 4GB 8GB 16GB

You can ask what the state of things is at any time, without changing anything:

    sudo /usr/local/sbin/hp-rebar-sleeper.sh check

## Uninstall

    sudo bash ./install.sh --uninstall

Then reboot. That removes the service, the script and the GRUB drop-in, and
leaves `/etc/hp-rebar-sleeper.conf` alone if you wrote one. Your BAR goes back
to what the firmware gives it.

**If the machine will not start**, hold Shift during boot to get the GRUB menu,
press `e`, and add this to the end of the line beginning `linux`:

    systemd.mask=hp-rebar-sleeper.service

Press Ctrl-X to boot. That starts the machine with this turned off, and you can
uninstall from there.

## Verified systems

| Machine | Generation | Cards | Driver | Result |
|---|---|---|---|---|
| HP Z230 | Haswell, 2013 | B580 | `xe` | 16 GiB |
| HP Z230 | | Pro B60 + A310 | `xe` + `i915` | 32 GiB + 4 GiB |
| HP Z240 | Skylake, 2015 | B580 | `xe` | 16 GiB |
| HP Pavilion h8 | Sandy Bridge, 2011 | A770 | `i915` | 16 GiB, see the appendix |

All on Ubuntu 26.04.

### Will my other cards still work?

`pci=nocrs` changes how Linux assigns addresses to **every** PCIe device, not
just the graphics card. In testing, an NVMe SSD on a PCIe adapter card kept
working normally and was partitioned, written and read back; and a second
graphics card — an NVIDIA GT 1030 and a Quadro K2000, both on `nouveau`, and
separately an Arc A310 — kept working alongside a card holding a large BAR.
Every onboard controller on the test machines ran under it throughout: network,
USB, SATA, audio.

Add-in network cards and HBA/RAID controllers were not tested. Nothing is
written to firmware, so if one of them misbehaves, uninstall and reboot.

### HP Z240: turn integrated graphics off

With integrated graphics enabled in the BIOS, the Z240 **will not start at all**
with an Intel Arc card fitted. It stops before the OS with diagnostic code 3.3,
"the embedded controller has timed out waiting for BIOS to return from graphics
initialization". Seen with both an A310 and a B580.

Turn integrated graphics off before fitting an Arc card. An NVIDIA card in the
same slot starts fine with integrated graphics on, so this is specific to having
both an Intel integrated GPU and an Intel Arc card.

<sub>There is a way around it, but it is not something to rely on: start the
machine once with a non-Intel card fitted and integrated graphics on, shut down,
and swap the Arc card in. The firmware keeps that state until its settings are
reset, and a CMOS clear or a BIOS update undoes it.</sub>

## Messages you can ignore

**`snd_hda_intel 0000:xx:xx.x: Unknown capability 0`**

This is the HDMI audio function on the Arc card, not the graphics side. Audio
works; HDMI sound was confirmed playing on a monitor attached to the card.

**`lspci` reporting a 2.5GT/s x1 link**

Arc cards drop their link to save power when idle, and `lspci` reports what the
link is doing at that moment, not what it is capable of. For the real width, ask
the root port above the card instead:

    sudo lspci -vv -s 0000:00:01.0 | grep -E 'LnkCap:|LnkSta:'

## When it does not work

| What you see | Why | What to do |
|---|---|---|
| `driver 'xe' is already bound ... resizing now would hang the machine` | The driver got there first; `modprobe.blacklist=` is missing or wrong | Check `cat /proc/cmdline` against what `hp-rebar-sleeper.sh check` prints |
| `BAR2 unassigned. 16 GiB does not fit here.` followed by `rolling back` | There is not enough address space above your RAM | The machine boots normally with the original BAR. See the appendix |
| Wrong screen resolution and nothing can see the card, after uninstalling by hand | `modprobe.blacklist=` was left on the kernel command line, so no driver loads | `sudo modprobe i915` (or `xe`) fixes the screen at once; remove the argument and reboot for the BAR |
| The machine stops before the OS, power LED blinking red and white | This is the firmware, not this project | Count the blinks: red is the major number, white the minor. `3.3` is a graphics initialisation timeout |
| Cycles fails with a oneAPI initialization error | Blender, not the BAR | Turn off **Preferences → System → Embree on GPU**. Blender may switch it on by itself after an update |

## How it works

Two things are missing on these machines. The firmware publishes no MMIO window
above 4 GiB, so Linux has nowhere to put a large BAR; and
`pci_resize_resource()` only reprograms the bridge directly above the device,
while Arc cards put a PCIe switch between the GPU and its root port, so growing
the BAR at runtime fails with `-ENOSPC`.

`pci=nocrs` makes Linux ignore the firmware's description and treat the whole
physical address space as available. The service then writes the wanted size
into the card's Resizable BAR capability with `setpci`, removes the root port
and rescans, which makes Linux size every bridge window in the chain at once.

If the BAR cannot be placed, the service puts the old size back and the machine
boots normally without a large BAR.

## Configuration file

Optional, `/etc/hp-rebar-sleeper.conf`:

    SKIP="0000:0a:00.0"    # leave this card alone
    MAX_SIZE_IDX=13        # never ask for more than 2^13 MiB = 8 GiB

---

# Arc Pro B60

The B60 is a different case and most of the page above does not apply to it.

## There is nothing to resize

The Pro B60 24GB advertises a 32 GiB BAR out of the box. All you need is
`pci=nocrs` on the kernel command line. No service, no `modprobe.blacklist=`, no
`setpci`. Running `hp-rebar-sleeper.sh check` on such a machine says so.

## You need a second graphics card

The B60 will not bring a machine up on its own. The firmware hangs during
graphics initialisation and the machine stops before the OS loads — on the Z230
the fan does not even spin. Fit a second graphics card to handle startup and the
B60 works normally once Linux has loaded.

The second card can be anything, another Arc or an NVIDIA card, **as long as its
video BIOS supports UEFI**. A card old enough to have a legacy-only video BIOS
will not come up on a machine running without CSM.

Integrated graphics is not enough. The Z230 has no integrated GPU at all and
fails in exactly the same way, so the problem is the absence of a second PCIe
graphics card, not the absence of a display.

## Two Arc cards together

A Pro B60 and an A310 run together on the Z230, on different root ports, under
different drivers, both with large BARs:

    0000:03:00.0: BAR is already 32 GiB. Nothing to do.
    0000:0a:00.0: 256 MiB -> 4 GiB (driver i915, root port 0000:00:1c.4)
    0000:0a:00.0: ReBAR control 0x00000822 -> 0x00000c22
    unbinding simpledrm from simple-framebuffer.0
    removing 0000:00:1c.4 subtree
    rescanning
    0000:0a:00.0: BAR2 0x0000000900000000-0x00000009ffffffff (4096 MiB)
    loading xe
    loading i915

The A310 drove the display and handled startup; the B60 did the work. Blender
rendered on each card alone and on both at once.

## The Z240 will not start with one

No arrangement works. Integrated graphics on or off, with a second graphics card
or without, in either slot: the machine stops with diagnostic code 3.3 whenever
a B60 is fitted. The Z230 falls back to another graphics card when one fails to
initialise; the Z240 waits for it and gives up.

<sub>My own take: if you are buying a machine for a B60, get a Z230 rather than
a Z240. Secondhand they cost less, and for an Arc card the extra years buy you
nothing. This is an opinion, not a measurement.</sub>

---

# Appendix: 36-bit machines

The HP Pavilion h8 is a 2011 Sandy Bridge desktop with an i7-2700K. It works,
with two things worth understanding.

## This h8 has a modified BIOS, for an unrelated reason

The machine runs `IPISB-CH_GPU-fix-v2`, a modified BIOS flashed from Windows.
All it does is turn legacy mode off. It does not add Above 4G Decoding, it has
no Resizable BAR setting, and the large BAR described here does not come from
it — that comes from the method on this page, the same as on every other
machine listed.

It is there because an Arc card carries no legacy video BIOS and will not start
on a machine still booting in legacy mode. On a 2011 consumer board that has to
be dealt with before anything on this page is relevant. A newer machine that can
be put into UEFI-only mode from its own setup screen needs nothing of the kind.

If you are working on an h8 of your own and an Arc card gives you no picture at
all, that is the problem to solve first, and it is a different problem from the
one this project is about.

## There is only just enough address space

Sandy Bridge addresses 36 bits, so 64 GiB of physical address space, and the
machine has 32 GB of RAM in it. That leaves about 31 GiB free above the top of
RAM, and only one 16 GiB-aligned slot inside it. A 16 GiB BAR needs that slot
and about 8 MiB more, to cover the small BAR on the card's own PCIe switch
within the same bridge window.

On kernel 6.8 it fits. On kernel 7.0 it does not, and the service puts the
original BAR back:

    BAR2 unassigned. 16 GiB does not fit here.
    rolling back to 256 MiB
    BAR2 after rollback: ...

**The machine boots normally either way.** You simply do not get the large BAR
under 7.0. If you want it there, boot a 6.8 kernel, or fit less RAM, or set
`MAX_SIZE_IDX` in the configuration file to ask for a size that does fit.

For the record, on this machine an A770 held a 16 GiB BAR while an NVMe SSD on a
PCIe adapter card and a second Arc card were installed. All three were
enumerated and assigned resources, and the SSD was partitioned, written and read
back normally.

---

## Related projects

- [arc-rebar](https://github.com/RodBurlamaqui/Intel-ARC-Rebar) — the same core
  idea, but it requires Above 4G Decoding in the BIOS.
- [precision-5820-arc-b60-large-bar](https://github.com/skipzx-lab/precision-5820-arc-b60-large-bar)
  — changes a hidden BIOS setting with `setup_var.efi`.
- [geforce-bar1-resize](https://github.com/noon-at-cgn/geforce-bar1-resize)
  — a boot-time BAR resize for GeForce cards.

This project is for machines whose BIOS has no Above 4G Decoding option at all.
If yours has it, the first two are simpler paths.

---

## License and credits

Released under [CC0 1.0](LICENSE). Do what you like with it: modify it,
redistribute it, fold it into something else. No attribution required.

Written with the help of Claude (Anthropic), which also did most of the log
reading and the bisecting.

If it works on a machine not listed above, or fails on one, an issue saying so
would be useful. The output of

    sudo /usr/local/sbin/hp-rebar-sleeper.sh check

plus `cat /proc/cmdline` is enough to tell what happened.
