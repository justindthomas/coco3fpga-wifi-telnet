# File Transfer Protocol

`wtbridge` accepts file uploads on the same TCP port as telnet (23)
by sniffing the first bytes of every new connection.  This document
describes the wire format and how the bridge multiplexes interactive
shells against file-upload sessions on the single CIPMUX=1 server.

## Why this design

The ESP8266 AT firmware only supports **one** active TCP server
(`AT+CIPSERVER` replaces, not adds), so there is no way to listen on
two ports simultaneously.  CIPMUX=1 does, however, give us five
simultaneous client connections (link IDs 0-4) on that one server, of
which the telnet bridge currently uses three.  We use the remaining
capacity by repurposing link IDs at the protocol layer: every
incoming connection starts out *unbound*, and the first few bytes the
client sends determine whether the link gets routed to an OS-9 shell
or to a file sink.

## Wire format

Client → server, sent immediately after the TCP connection
completes:

```
+------+--------+--------+--------+
| 'W'  |  'T'   |  'U'   |  'P'   |   4-byte magic
+------+--------+--------+--------+
|  nameLen (1 byte, 1..240)       |   length of path string
+---------------------------------+
|  name (nameLen bytes, ASCII)    |   NitrOS-9 path, e.g. /dd/CMDS/foo
+---------------------------------+
|  size  (4 bytes, big-endian)    |   total payload length in bytes
+---------------------------------+
|  payload (size bytes, opaque)   |   file contents
+---------------------------------+
```

Server → client, after the final payload byte is received and
flushed:

```
+--------+
| status |    1 byte: see status codes
+--------+
```

The server then closes the connection (`AT+CIPCLOSE=<link>`).  The
client should read the status byte before its socket EOFs.

### Status codes

| code | meaning |
|------|---------|
| `0`  | OK — file written, size matched header |
| `1`  | open failed (`F$Open` returned error — see system errno table) |
| `2`  | write failed mid-stream (`I$Write` returned error) |
| `3`  | nameLen out of range (must be 1..240) |
| `4`  | size too large (we currently cap at 65535 bytes) |
| `5`  | another upload is already in progress |

## Magic byte rationale

The bridge filters incoming +IPD payload bytes for telnet hygiene:
LF (`$0A`) is dropped (telnet sends CR+LF, the shell only wants CR)
and bytes `>= $80` are dropped (so telnet IAC negotiation doesn't
reach the shell).  Any magic header has to survive that filter, so
the four bytes `W T U P` (`$57 $54 $55 $50`) were chosen — all under
`$80`, none equal to `$0A`, and not a sequence any real telnet client
sends unprompted.

Once the bridge has seen all four magic bytes on a given link, it
disables the telnet filter for that link's remaining payload bytes
so that 8-bit-clean binary data (including the high bytes of the
size field and the file body) flows through verbatim.

## Link state machine

Each link ID (0..4) has a `linkMode` that starts at `UNBOUND` and
transitions on the first few bytes the client sends:

| state | meaning | exits on |
|-------|---------|----------|
| `UNBOUND`    | new connection, sniffing magic | 4 bytes received → `FILE_HDR` or `TELNET` |
| `TELNET`     | bound to a free `/wt`/`/wt1`/`/wt2` slot, filtered | connection close → `UNBOUND` |
| `FILE_HDR`   | reading nameLen + name + sizeBE       | full header parsed → `FILE_BODY` |
| `FILE_BODY`  | writing payload bytes to the open file | byteCount == size → status reply, close, → `UNBOUND` |

Note that **all** new connections sniff for the magic — the bridge
does *not* assume telnet on link 0 and file upload on link 3.  ESP
assigns link IDs in connection-arrival order, so a file-upload client
that connects first will get link 0 and must still announce itself
with the WTUP magic.

## Concurrency

The header-parser state (current name, expected size) is **global**
to the bridge; only one file upload may be in progress at a time.
If a second `WTUP` arrives while another upload is mid-stream, the
bridge responds with status `5` and closes the second link.

This is a deliberate simplification — concurrent uploads would
require per-link header buffers and weren't worth the SRAM at v5.

## Client-side reference

See `client/wtsend/` for the Rust implementation.  Minimal usage:

```
wtsend --host 192.168.1.50 --remote /dd/CMDS/myprog ./myprog.bin
```
