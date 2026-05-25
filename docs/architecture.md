# Architecture

## The two halves of the pseudo-terminal

`scwpt` is an SCF (sequential character file) driver, so as far as
NitrOS-9 is concerned, `/wt` is just a terminal.  The "hardware"
behind it is two in-memory ring buffers in driver static storage:

| name | direction        | who writes              | who reads      |
|------|------------------|-------------------------|----------------|
| m2s  | master → slave   | `wtbridge` via SS.WtPush| SCF.readln (shell stdin) |
| s2m  | slave → master   | SCF.write (shell stdout)| `wtbridge` via SS.WtPull |

Each buffer is 256 bytes, with a 1-byte head and 1-byte tail (which
wrap naturally on overflow) and a 16-bit count.

SCF sits above the driver and provides everything you'd expect from a
real terminal: line editing, echo, CR→CRLF (PD.ALF=1), interrupt
character handling, etc.  The driver itself is dumb byte plumbing.

## Custom SetStat / GetStat codes

The driver responds to the standard SCF codes (Open, Close, SSig,
Relea, ScSiz) plus three custom codes for the master side:

| code | dir     | purpose |
|------|---------|---------|
| `$80` | SetStt | **SS.WtPush** – copy bytes from caller into m2s |
| `$81` | GetStt | **SS.WtPull** – copy bytes from s2m into caller |
| `$82` | SetStt | **SS.WtHup**  – send S$HUP to the path's owner   |

Caller passes `X = buffer`, `Y = max bytes` and gets `Y = actual
count` back.  Both Push and Pull use F$LDABX / F$STABX to copy across
task boundaries; both U *and* Y are saved across those syscalls
(they're documented as not-preserved by the kernel).

## Sleep / wake without deadlocking

The slave-side `Read` / `Write` block when their buffer is empty/full.
A naive `F$Sleep` loop holding V.BUSY would deadlock the master side
of the same device, so each blocking path:

1. `clr V.BUSY,u`           – release the device lock.
2. `F$Sleep(1 tick)`        – give CPU back to the scheduler.
3. Loop, re-check.
4. On wake with data, `sta V.BUSY,u` with our own PID – reclaim it.

This lets `wtbridge`'s `SS.WtPull` / `SS.WtPush` slip in while the
shell is sleeping inside SCF.readln.

## Shell+ requires SS.SSig

Shell+ (the default NitrOS-9 shell) doesn't sit in a blocking
`I$ReadLn`.  Instead it does:

```
SS.Relea  any pending signals
SS.SSig   send-signal-on-data <my-PID, my-signal>
F$Sleep   until that signal fires
I$ReadLn  now read the line
```

If the driver doesn't implement `SS.SSig`, the signal never arrives
and the shell wedges forever in `F$Sleep`.  Our driver:

- On `SS.SSig`: stash the caller's PID + signal in `SSigID` /
  `SSigSg`.  If m2s already has data, F$Send the signal immediately
  (so we don't drop the wake).  Either way, also stash the PID in
  `SHupID` for the hangup path.
- On `WtPush` (after data lands in m2s): if `SSigID != 0`, F$Send
  the signal and clear `SSigID` (one-shot; shell re-arms next round).
- On `SS.Relea` or `SS.Close`: clear all of `SSigID` / `SHupID` /
  buffer state so the next session starts clean.

## Disconnect routing

`wtbridge` watches the ESP's text stream for `CLOSED`.  When it
matches, it looks at the most recent decimal digit it saw and treats
that as the link ID that just dropped (ESP sends `<id>,CLOSED\r\n`).

On match, `wtbridge` does an `I$SetStt SS.WtHup` on the corresponding
`/wt<id>`.  The driver F$Sends `S$HUP` to `SHupID`, the shell process
exits, and tsmon's `F$Wait` returns – it goes back to its read loop,
ready to fork login for the next client.

## Multi-link routing

Three device descriptors – `/wt`, `/wt1`, `/wt2` – each with a unique
controller address (`$0000`, `$0001`, `$0002`).  Without unique
addresses, iniz folds them into one `V$STAT` and they all share the
same ring buffers, which we discovered the hard way.

`wtbridge` opens all three at startup and keeps an array `paths[3]`
of OS-9 path numbers.  When a `+IPD,<id>,<len>:<payload>` frame
arrives, the parser stashes `<id>` in `curLink` and PushFrame routes
to `paths[curLink]`.  In the other direction, the main loop iterates
`iLink = 0..2`, pulls each path's s2m, and on non-empty calls
`DoCipsend` with `sendLink = iLink` – which becomes the `<id>` in
the `AT+CIPSEND=<id>,<n>` command.

## Why the boot file is 121 sectors

OS-9's bootstrap loads `OS9Boot` from contiguous disk sectors.  If
`os9 gen` can't allocate the file contiguously it prints
"is fragmented" and refuses.  The disk image we target tops out at
121 contiguous sectors before fragmentation begins, so we drop unused
modules (extra graphics windows, /N4..N13, RAMD, midi, etc.) to make
room for scwpt + the three wt descriptors.  See `boot/build_boot.py`.
