# Wire Protocol Notes

## ESP8266 FIFO

The CoCo3FPGA exposes the ESP8266 UART through two MMIO registers:

| addr   | r/w | meaning |
|--------|-----|---------|
| `$FF6C` | W   | control: bit 7 IRQ enable, bits 1-0 baud rate (we use 0) |
| `$FF6C` | R   | status:  bit 1 RDAVAIL (RX has a byte), bit 0 WRFULL (TX full) |
| `$FF6D` | RW  | data:    read pops RX FIFO, write pushes TX FIFO |

We never use IRQs – `wtbridge` polls in a F$Sleep(1)-paced loop.

## ESP AT setup we depend on

```
AT+CIPMUX=1         # multi-connection mode
AT+CIPSERVER=1,23   # TCP server, port 23 (telnet)
```

In CIPMUX=1, ESP wraps each incoming TCP datagram as a +IPD frame and
labels every outbound CIPSEND with a link ID (0..4).

## +IPD parsing

When a client sends data, ESP delivers it to the host as:

```
+IPD,<id>,<len>:<len bytes of raw data>
```

The state machine in `wtbridge.asm:ParseByte`:

| state | meaning                            | exits on                    |
|-------|------------------------------------|-----------------------------|
| 0     | scanning for `+IPD,`               | full match → state 1        |
| 1     | reading single-digit `<id>`        | `,` → state 2, save curLink |
| 2     | reading decimal `<len>` (Mul10Add) | `:` → state 3, plen ready   |
| 3     | reading `<len>` payload bytes      | plen exhausted → PushFrame  |

Two filter rules in state 3:

- `$0A` (LF) is dropped – telnet sends CR+LF for end-of-line and the
  shell only wants the CR.
- bytes `>= $80` are dropped – telnet IAC negotiation otherwise lands
  in the shell as illegal chars (`ERROR #215`).

Payload bytes that survive are appended to `inbuf`.  On plen=0,
`PushFrame` does `I$SetStt SS.WtPush` against `paths[curLink]`.

## CLOSED detection

In scan state, the parser also looks for the literal string
"CLOSED".  Whenever a decimal digit goes by, it's stashed in
`lastDig`.  On a complete "CLOSED" match, we know the most recent
digit is the link ID ESP just dropped, and we fire
`I$SetStt SS.WtHup` against `paths[lastDig]`.

This is per-byte while in scan state only – so a literal "CLOSED" in
the shell's input stream (state 3 payload) won't trigger a phantom
hangup.

## CIPSEND back to the client

For each link with data in s2m, `DoCipsend` sends:

```
AT+CIPSEND=<sendLink>,<decimal-length>\r\n
```

Then waits for ESP's `>` prompt (DC_wait, ~8s timeout), sends the
payload bytes, and drains ESP's `\r\nSEND OK\r\n` response (DC_done,
waits for a final LF, then F$Sleep(3) before returning).

Two robustness measures:

- **Drain before send.** `DoCipsend` starts by consuming any pending
  ESP output (async "0,CONNECT", leftover SEND OK, etc.) so DC_wait
  doesn't have to parse stale bytes while looking for the new `>`.
- **Timeout filler.** If DC_wait times out without seeing `>`, we
  assume ESP entered data-mode and is waiting for `<n>` bytes, so we
  send N NULs and F$Sleep(60) to let ESP return to command mode.
  The current payload is lost but the bridge stays usable.

## Why we strip the IAC bytes

A standard telnet client sends an IAC negotiation burst as the first
bytes of every connection, like:

```
FF FB 03   IAC WILL SUPPRESS-GO-AHEAD
FF FD 03   IAC DO   SUPPRESS-GO-AHEAD
FF FB 01   IAC WILL ECHO
FF FD 01   IAC DO   ECHO
```

We don't honor any of this – we just drop anything with bit 7 set.
SCF on the host does its own line editing and echo regardless of what
telnet thinks.  The option codes that follow IAC (e.g. `01` ECHO,
`03` SGA) are below `$80`, so they'd otherwise reach the shell as
literal Ctrl-A / Ctrl-C bytes.  PD.DUP (`$01`) and PD.INT (`$03`)
absorb them in SCF.readln when the buffer is empty, so they're a
no-op rather than a crash, but the dropouts still confuse the parser.
The `>= $80` filter is what catches the IAC marker itself.
