# CoCo3FPGA WiFi Telnet Bridge

Bridges the WiFi interface ($FF6C/$FF6D, ESP8266) on the CoCo3FPGA
analog board to NitrOS-9 Level 2, exposing a real OS-9 shell over
telnet on port 23.  Multiple simultaneous clients (up to 3) each get
their own independent shell.

## Architecture

```
   telnet client            ESP8266 (CIPMUX=1, CIPSERVER=1,23)
       ^      \             /         \
       |       +--- TCP ---+   AT cmd  \  +IPD frames
       v                              \  v
                              FPGA $FF6C/$FF6D (UART FIFO)
                                       ^   |
                                       |   v
                                wtbridge (user-space)
                                       ^   |
                              SS.WtPull|   |SS.WtPush
                                       |   v
                          scwpt SCF driver (m2s/s2m ring buffers)
                                       ^   |
                              SCF echo |   | shell input
                                       |   v
                              shell / login / tsmon on /wt /wt1 /wt2
```

`scwpt` is an SCF driver that backs `/wt`, `/wt1`, `/wt2` (three
descriptors so three clients can run in parallel).  Each device has
two in-memory ring buffers in driver static: **m2s** (master → slave,
holds bytes that telnet typed) and **s2m** (slave → master, holds
bytes the shell wrote).  SCF above the driver does normal line
editing, echo, autolf, etc.

`wtbridge` is a user-space process that owns the WiFi FIFO and pumps
both directions:

- Parses `+IPD,<link>,<len>:<payload>` from ESP, strips telnet IAC
  bytes, `SS.WtPush`es the payload into `/wt<link>`'s m2s.
- `SS.WtPull`s each device's s2m and sends the bytes back via
  `AT+CIPSEND=<link>,<n>`.
- Watches for `<link>,CLOSED` and fires `SS.WtHup` so the shell on
  that link gets `S$HUP` and exits, letting tsmon fork a fresh login
  for the next client.

`scwpt` implements `SS.SSig` (required by Shell+) and signals the
sleeping shell whenever a push lands data in m2s.

## Files

```
src/
  scwpt.asm      SCF driver (pseudo-terminal w/ m2s + s2m rings)
  wt.asm         /wt device descriptor (controller addr $0000)
  wt1.asm        /wt1 device descriptor (controller addr $0001)
  wt2.asm        /wt2 device descriptor (controller addr $0002)
  wtbridge.asm   user-space WiFi <-> /wt[N] bridge
  wtping.asm     diagnostic: push a string and dump whatever comes back
  wifi.asm       send a raw AT command to the ESP8266 and show the reply

boot/
  build_boot.py  assembles OS9Boot: pristine - unused modules + ours
  startup        iniz/tsmon for /wt[N], wifi setup, wtbridge&

docs/
  architecture.md  ring-buffer flow, SS.SSig wiring, hangup semantics
  protocol.md      +IPD parsing, CLOSED detection, ESP CIPSEND format
```

## Building

Prerequisites:

- A C toolchain (`make`, `cc`) – for building the vendored toolshed.
- [`lwasm`](http://www.lwtools.ca/) on PATH – the 6809 assembler.
  Install on macOS: `brew install lwtools`.
- Python 3 – for `boot/build_boot.py`.

The `os9` / `decb` utilities are **not** required on PATH; toolshed
is vendored as a git submodule and `make tools` builds it into
`build/tools/`.  After cloning:

```
git clone <this repo>
cd coco3fpga-wifi-telnet
git submodule update --init     # pulls vendor/toolshed
```

Required pointers (set as env or pass on the make line):

- `NITROS9_SRC` – path to a NitrOS-9 v3.3.0 source tree.  Used both
  for the shared `defsfile` / `os9.d` / `scf.d` headers our `.asm`
  files include AND (for `fromscratch`) as the upstream source we
  build the base disk from.  Get it from the
  [NitrOS-9 project](https://nitros9.sourceforge.net/).
- `DISK` – `.dsk` image to install into.  Must already contain a stock
  NitrOS-9 boot; we pull `OS9Boot` from it on first run as our
  pristine baseline (cached as `build/OS9Boot.pristine`).  Only
  needed for `make install`; `make fromscratch` builds its own.
- `PRISTINE` – optional override if you'd rather supply the baseline
  yourself instead of extracting from `$(DISK)`.

```
# Build vendored toolshed once (also done implicitly by the targets
# below, but you can run it explicitly to confirm your tree is happy):
make tools

# Assemble modules only:
make NITROS9_SRC=~/code/nitros9-v3.3.0

# Install onto an existing NitrOS-9 disk:
make install NITROS9_SRC=~/code/nitros9-v3.3.0 \
             DISK=~/code/drivewire-rs/disks/nos96809l2v030300coco3fpga_becker.dsk

# Build a fresh NitrOS-9 disk from source and install everything
# onto it - no preexisting disk required:
make fromscratch NITROS9_SRC=~/code/nitros9-v3.3.0
# (result: build/disk.dsk, ready to boot the FPGA from.)
```

`make fromscratch` invokes the upstream NitrOS-9 level2/coco3 makefile
to produce a stock becker-variant disk, then layers our boot + CMDS +
startup on top.  Set `NITROS9_VER` if your NitrOS-9 tree isn't the
default `v030300` release.

The upstream v3.3.0 source has a few rough edges under current lwasm
(`level1/cmds/edit.asm` uses `pulu pc,u`, which is ambiguous on the
6809) and references 3rdparty packages that aren't shipped in the
v3.3.0 source archive (`basic09`, `gfx2`, `inkey`, `syscall`, `tmode`,
`inetd`, `dw`, `telnet`, `httpd`).  `patches/cmds-minimal.patch` drops
those targets from the CMDS lists so a stock source tree builds
cleanly; the patch is applied to `NITROS9_SRC` automatically (and
idempotently) by `make fromscratch`.

## Usage

### First-time WiFi provisioning

The `startup` script assumes the ESP8266 has already associated with
your WiFi network and that ESP-AT has persisted the credentials in
its own flash (it does, by default, since AT firmware ≥ 1.5).  On
a brand-new ESP you need to join the network once from a local
shell:

```
# Skip the wifi/wtbridge bits in startup by booting to a local shell
# first (interrupt startup or boot a disk without it), then:

wifi AT+CWMODE=1                    # station mode
wifi AT+CWJAP="<ssid>","<password>" # join (saved to ESP flash)
wifi AT+CIFSR                       # confirm: shows the assigned IP
```

The next reboot will pick up the saved credentials automatically and
the normal `startup` flow will work.  Verify any time with
`wifi AT+CWJAP?` (currently associated AP) or `wifi AT+CIFSR` (IP
address).

To switch networks later: `wifi AT+CWJAP="<new-ssid>","<new-pw>"`
overwrites the saved entry.  To forget the saved network:
`wifi AT+CWQAP`.

### Normal operation

After the disk is installed and the FPGA is reloaded:

1. NitrOS-9 boots, runs `startup`, which configures the ESP for TCP
   server mode on port 23 and starts `wtbridge&` in the background.
2. From any host: `telnet <coco-ip>` → login prompt.
3. Up to three simultaneous telnet clients are routed to `/wt`,
   `/wt1`, `/wt2`.  Disconnecting a client hangs up that shell;
   the next telnet to that link gets a fresh login.

Single-client diagnostics:

```
wtping U          # push "U<CR>" into /wt's m2s, sleep, dump s2m
wifi AT+CIPSTATUS # send raw AT command, show reply
```

## License

Public domain.  Use, modify, ship at will.
