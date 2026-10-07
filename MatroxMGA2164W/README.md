# MatroxMGA2164W: Matrox Millennium II display driver for OPENSTEP 4.2 (x86)

A DriverKit `IOFrameBufferDisplay` driver for the Millennium II (MGA-2164W with
a TVP3026 RAMDAC; PCI IDs `102b:051b` and `102b:051f`, PCI and AGP). The driver
Matrox shipped with OPENSTEP matches the original Millennium (`0x0519`), and it
reprograms the BARs itself in the Millennium I layout, so it never binds to a
Millennium II and the machine falls back to the generic VGA driver.

Tested in 86Box (Millennium II AGP, 16 MB) on OPENSTEP 4.2 with User and
Developer Patch 4. **Not yet tried on real hardware.**

## What it does

* Uses the BIOS-assigned BARs: BAR0 is the 16 MB linear framebuffer and BAR1
  the 16 KB control registers.
* Sizes VRAM by probing for aliasing (the MGA-2164W cannot report it; 16 MB
  interleaved is detected in 86Box).
* Modes: 640x480, 800x600, 1024x768 and 1280x1024 at 60 and 75 Hz, each at
  8-bit colour, 8-bit gray, 15-bit (RGB:555/16) and 32-bit (RGB:888/32). Choose one
  with the `"Display Mode"` key (see below).
  Tested: 640x480x8, 800x600x16, 800x600 gray, 1024x768x8@75, 1024x768x32,
  1280x1024x32 and 1280x1024x16@75. Others in the table share the same code
  but were not individually tried.
* Hardware palette at 8 bpp (transfer table and brightness), software gamma at
  15/32 bpp.
* **MTRR write combining** for the framebuffer aperture (see below).
* **Hardware cursor** (TVP3026), see below.
* No blitter yet; the window server draws everything else.

## Install

On the OPENSTEP machine, as root:

    sh install.sh            # uses prebuilt/MatroxMGA2164W.config
    /etc/shutdown -r now

`install.sh` copies the bundle to `/usr/Devices`, saves
`System.config/Instance0.table` as `Instance0.table.pre-mga2164`, and edits the
`"Active Drivers"` line, replacing `MatroxMGA2064WDisplayDriver` with
`MatroxMGA2164W` (or appending it). Then use Configure.app as usual, or edit
the bundle's `Instance0.table`:

    "Display Mode" = "Height: 768 Width:1024 Refresh: 60Hz ColorSpace: RGB:888/32";

Mode strings are `Height:<h> Width:<w> Refresh: <60|75>Hz ColorSpace: <RGB:256/8|BW:8|RGB:555/16|RGB:888/32>`
(pad the numbers to the widths shown, as in the other DriverKit drivers).
The default is `Height: 480 Width: 640 Refresh: 60Hz ColorSpace: RGB:256/8`.

### Roll back

If the display does not come up, log in over the network (or boot single-user)
and restore the saved table, then reboot:

    cp /usr/Devices/System.config/Instance0.table.pre-mga2164 \
       /usr/Devices/System.config/Instance0.table

### Other config keys

| Key | Values | Default |
|---|---|---|
| `Display Mode` | see above | 640x480x8 |
| `WriteCombining` | `Yes` / `No` | `Yes` |
| `HardwareCursor` | `Yes` / `No` | `Yes` |
| `DisplayCacheMode` | `Off` / `WriteThrough` / `CopyBack` | `WriteThrough` |

## Hardware cursor

The TVP3026 has a 64x64 cursor with two colours plus transparent. OPENSTEP
keeps the 16x16 cursor bitmaps (premultiplied alpha, in the pixel format of the
current depth) in a shared state block that `IOFrameBufferDisplay` keeps in its
private `priv` ivar, and draws them in software. The driver overrides
`showCursor:`, `moveCursor:` and `hideCursor:`, reads the same block (layout in
the comments in `MatroxMGA2164W.m`, found by disassembling the 4.2 kernel's
superclass), and loads an image into the DAC's cursor RAM:
pixels with alpha below 50% are transparent, the rest are split by
luminance into a dark and a light colour, each set to the average colour of its
group. Anti-aliased edges therefore become hard edges, but the standard arrow,
I-beam and so on look the same as the software cursor. It depends on a private
offset (`priv` at +0x1fc) of the 4.2 kernel; set `HardwareCursor = No` to fall
back to the superclass's software cursor.

Checked in 86Box at 8-bit colour, 15-bit and 32-bit (a debug build with a red foreground colour
confirmed the DAC draws it). Cursor movement was checked by hand in 86Box (no lag, no artifacts).

## Write combining

OPENSTEP maps the framebuffer WriteThrough by default, and on a P6-class CPU
the firmware's MTRRs leave a PCI aperture uncached (UC). On load the driver
looks for a free variable MTRR, checks it overlaps nothing, and programs
base = BAR0, size = the BAR size, type = WC, using the cache-disable /
`wbinvd` / MTRR-disable protocol from the Intel SDM (single CPU only). The
MTRR is cleared again when the driver is freed. The load logs a cycle count for
a 256 KB write before and after, e.g. in `/usr/adm/messages`:

    Display0: write combining on (MTRR2, 0xe1000000 + 0x1000000); 256 KB write: A -> B cycles

It skips (and says so) when there is no CPUID/MTRR support, no WC support, MTRRs are
disabled, the range overlaps an existing MTRR, or no variable MTRR is free. 86Box
does not emulate MTRRs, so the speedup has **not** been measured; the
programming sequence runs without faulting.

## Build

On the OPENSTEP machine with the developer tools: copy `src/` there (use
`COPYFILE_DISABLE=1 tar --format ustar` on a Mac, or NeXT `tar` chokes on
pax headers) and run `sh build.sh` inside it.
The result is `src/MatroxMGA2164W.config`.

## Credits

TVP3026 and MGA-2164W register sequences, PLL arithmetic and CRTC extension
programming follow the X.Org `xf86-video-mga` driver (permissive licence, see
`NOTICE`), rewritten in integer arithmetic for the kernel.
