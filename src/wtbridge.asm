********************************************************************
* wtbridge - WiFi <-> /wt bidirectional bridge (v5)
*
* Single user-space process. Owns the WiFi FIFO ($FF6C/$FF6D) and the
* master side of the scwpt pseudo-terminal pool (/wt, /wt1, /wt2).
*
* Each main-loop iteration:
*   1. For each TELNET-bound link: SS.WtPull the device's s2m, and if
*      anything came back, AT+CIPSEND it to that link.
*   2. Drain the WiFi RX FIFO, feeding every byte through the +IPD
*      state machine.  Payload bytes are dispatched per-link to one
*      of three sinks: telnet shell (SS.WtPush), file-header parser,
*      or open file (I$Write).
*   3. F$Sleep(1) if neither direction had work.
*
* Each link starts out UNBOUND.  The first four payload bytes choose
* a sink: "WTUP" => FILE_HDR for a wtsend upload; anything else =>
* TELNET, bound to the next free /wtN slot.  See docs/file-transfer.md.
*
* ESP must be in TCP server mode (AT+CIPMUX=1 / AT+CIPSERVER=1,23).

         nam   wtbridge
         ttl   WiFi <-> /wt + file bridge

         ifp1
         use   defsfile
         endc

tylg     set   Prgrm+Objct
atrv     set   ReEnt+rev
rev      set   $00
edition  set   5

WFCTL    equ   $FF6C
WFDAT    equ   $FF6D
WRFULL   equ   %00000001
RDAVAIL  equ   %00000010
SPIN     equ   $4000
SS.WtPush equ  $80
SS.WtPull equ  $81
SS.WtHup  equ  $82

INMAX    equ   256
OUTMAX   equ   256
NLINKS   equ   5                 ESP CIPMUX=1 supports link IDs 0..4
NTNPOOL  equ   3                 size of /wt SCF descriptor pool
FHNAMEMX equ   80                max filename length we accept

* Per-link mode values
LM_UNBOUND equ  0
LM_TELNET  equ  1
LM_FILEHDR equ  2
LM_FILEBODY equ 3

* File-header sub-states
FH_NEEDLEN equ  0
FH_NAME    equ  1
FH_SIZE    equ  2

* Status bytes returned to wtsend client
ST_OK      equ  0
ST_OPEN    equ  1
ST_WRITE   equ  2
ST_BADNAME equ  3
ST_TOOBIG  equ  4
ST_BUSY    equ  5

         mod   eom,name,tylg,atrv,start,size

         org   0
* Telnet pool: pre-opened paths to /wt, /wt1, /wt2
tnPath   rmb   NTNPOOL           OS-9 path numbers
tnOwner  rmb   NTNPOOL           link ID owning each slot ($FF = free)
* Per-link state
linkMode rmb   NLINKS            LM_*
linkPath rmb   NLINKS            OS-9 path: /wtN for TELNET, file for FILE_BODY
linkRem  rmb   NLINKS*2          uint16 remaining FILE_BODY bytes
magicMt  rmb   NLINKS            "WTUP" match progress (0..4, $FF = no)
* File-header parser (global, one upload at a time)
fhState  rmb   1
fhLink   rmb   1                 link currently owning the parser ($FF = idle)
fhNameLn rmb   1                 expected name length
fhNameOf rmb   1                 bytes of name received so far
fhName   rmb   FHNAMEMX+1        filename buffer (terminated with $0D)
fhSizeOf rmb   1                 bytes of sizeBE received so far
fhSizeHi rmb   2                 high 16 bits of sizeBE (must be 0)
fhSizeLo rmb   2                 low 16 bits of sizeBE = body length
* Parser / IO scratch
curLink  rmb   1                 link ID of the +IPD frame in flight
sendLink rmb   1                 link ID for the CIPSEND in progress
iLink    rmb   1                 main-loop drain iterator
lastDig  rmb   1                 last digit seen in scan state (for CLOSED)
state    rmb   1
match    rmb   1
ndig     rmb   1
active   rmb   1
dbgbyte  rmb   1
closeMt  rmb   1
statByte rmb   1                 scratch for status reply CIPSEND
plen     rmb   2
inlen    rmb   2
outlen   rmb   2
inbuf    rmb   INMAX
outbuf   rmb   OUTMAX
         rmb   400
size     equ   .

name     fcs   /wtbridge/
         fcb   edition

wt0name  fcc   "/wt"
         fcb   $0D
wt1name  fcc   "/wt1"
         fcb   $0D
wt2name  fcc   "/wt2"
         fcb   $0D
ipdstr   fcc   "+IPD,"
closeStr fcc   "CLOSED"
closeStrL equ   *-closeStr
cipcmd   fcc   "AT+CIPSEND="
cipcmdL  equ   *-cipcmd
clsCmd   fcc   "AT+CIPCLOSE="
clsCmdL  equ   *-clsCmd
magicStr fcc   "WTUP"
magicLen equ   *-magicStr
msgRdy   fcc   "wtbridge ready"
         fcb   $0D
msgRdyL  equ   *-msgRdy
msgPush  fcc   "[push n="
msgPushL equ   *-msgPush
msgPull  fcc   "[pull n="
msgPullL equ   *-msgPull
msgWait  fcc   "[esp byte=$"
msgWaitL equ   *-msgWait
msgGo    fcc   "[esp prompt seen, sending payload]"
         fcb   $0D
msgGoL   equ   *-msgGo
msgRaw   fcc   " raw bytes>>"
msgRawL  equ   *-msgRaw
msgSent  fcc   "[cipsend done]"
         fcb   $0D
msgSentL equ   *-msgSent
msgTimeout fcc "[cipsend TIMEOUT]"
         fcb   $0D
msgTimeoutL equ *-msgTimeout
msgPushed fcc "[pushed n="
msgPushedL equ *-msgPushed
msgErr   fcc "ERR]"
msgErrL  equ *-msgErr
msgCip1  fcc   "[cipsend cmd]"
         fcb   $0D
msgCip1L equ   *-msgCip1
msgCip2  fcc   "[awaiting >] esp:"
msgCip2L equ   *-msgCip2
msgCip3  fcb   $0D
         fcc   "[sending payload]"
         fcb   $0D
msgCip3L equ   *-msgCip3
crlfMsg  fcb   $0D
crlfMsgL equ   *-crlfMsg

start    pshs  x
         tfr   dp,a
         clrb
         tfr   d,u
         puls  x
* Open /wt /wt1 /wt2 into the telnet pool, mark all slots free.
         leax  wt0name,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   tnPath,u
         leax  wt1name,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   tnPath+1,u
         leax  wt2name,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   tnPath+2,u
         lda   #$FF
         sta   tnOwner,u
         sta   tnOwner+1,u
         sta   tnOwner+2,u
* Clear per-link state for all 5 links.
         ldb   #NLINKS
         leax  linkMode,u
SI_clm   clr   ,x+
         decb
         bne   SI_clm
         ldb   #NLINKS
         leax  linkPath,u
SI_clp   clr   ,x+
         decb
         bne   SI_clp
         ldb   #NLINKS*2
         leax  linkRem,u
SI_clr   clr   ,x+
         decb
         bne   SI_clr
         ldb   #NLINKS
         leax  magicMt,u
SI_clmm  clr   ,x+
         decb
         bne   SI_clmm
         lda   #$FF
         sta   fhLink,u
         clr   fhState,u
* Reset ESP FIFO + parser scratch.
         clra
         sta   >WFCTL
DrainLp  lda   >WFCTL
         bita  #RDAVAIL
         beq   DrainOk
         lda   >WFDAT
         bra   DrainLp
DrainOk  clr   state,u
         clr   match,u
         clr   closeMt,u
         clr   curLink,u
         lda   #$FF
         sta   lastDig,u
         ldd   #0
         std   inlen,u
         std   plen,u
         std   outlen,u
         leax  msgRdy,pcr
         ldy   #msgRdyL
         lbsr  Dbg

* === main loop ===
MainLp   clr   active,u

* --- 1) for each tnPool slot in use, drain its s2m and CIPSEND back. ---
         clr   iLink,u
ML_drain ldb   iLink,u
         cmpb  #NTNPOOL
         lbhs  ML_drainEnd
         leax  tnOwner,u
         lda   b,x
         cmpa  #$FF
         beq   ML_drainNext       slot free
         leax  tnPath,u
         lda   b,x                A = SCF path
         ldb   #SS.WtPull
         leax  outbuf,u
         ldy   #OUTMAX
         os9   I$GetStt
         lbcs  ML_drainNext
         cmpy  #0
         beq   ML_drainNext
         sty   outlen,u
         lda   #1
         sta   active,u
         ldb   iLink,u
         leax  tnOwner,u
         lda   b,x                A = TCP link ID
         sta   sendLink,u
         lbsr  DoCipsend
ML_drainNext
         inc   iLink,u
         lbra  ML_drain
ML_drainEnd

* --- 2) consume whatever the WiFi RX has and feed the parser ---
ML_rxLp  lda   >WFCTL
         bita  #RDAVAIL
         beq   ML_rxEnd
         lda   >WFDAT
         lbsr  ParseByte
         lda   #1
         sta   active,u
         bra   ML_rxLp
ML_rxEnd

* --- 3) sleep one tick if both directions were idle this round ---
         lda   active,u
         lbne  MainLp
         ldx   #1
         os9   F$Sleep
         lbra  MainLp

Exit     clr   iLink,u
EX_lp    ldb   iLink,u
         cmpb  #NTNPOOL
         bhs   EX_files
         leax  tnPath,u
         lda   b,x
         beq   EX_next
         os9   I$Close
EX_next  inc   iLink,u
         bra   EX_lp
EX_files clr   iLink,u
EX_flp   ldb   iLink,u
         cmpb  #NLINKS
         bhs   EX_done
         leax  linkMode,u
         lda   b,x
         cmpa  #LM_FILEBODY
         bne   EX_fnext
         leax  linkPath,u
         lda   b,x
         beq   EX_fnext
         os9   I$Close
EX_fnext inc   iLink,u
         bra   EX_flp
EX_done  clrb
         os9   F$Exit

* === ParseByte: feed byte A through the +IPD state machine ===
ParseByte
         ldb   state,u
         lbeq  PB_scan
         cmpb  #1
         lbeq  PB_id
         cmpb  #2
         lbeq  PB_len
* state 3: payload byte
* Dispatch per-byte by linkMode[curLink]:
*   FILE_HDR  - feed to header parser (no inbuf accumulation)
*   FILE_BODY - accumulate to inbuf, flush mid-frame if full
*   TELNET / UNBOUND - accumulate verbatim to inbuf; filter+dispatch
*                      at frame end via DispatchFrame
         pshs  a                      save byte
         ldb   curLink,u
         cmpb  #NLINKS
         lbhs  PB_drop                out-of-range link, drop
         leax  linkMode,u
         lda   b,x                    A = mode
         cmpa  #LM_FILEHDR
         beq   PB_phdr
         pshs  a                      save mode under byte
         ldd   inlen,u
         cmpd  #INMAX
         blo   PB_pstore
         lda   ,s                     mode (top of stack, byte beneath)
         cmpa  #LM_FILEBODY
         bne   PB_pdrop2              not file - drop excess
         lbsr  FlushBody              flush inbuf to file, inlen=0
PB_pstore
         leas  1,s                    discard mode
         leax  inbuf,u
         ldd   inlen,u
         leax  d,x
         puls  a                      restore byte
         sta   ,x
         ldd   inlen,u
         addd  #1
         std   inlen,u
         bra   PB_pcount
PB_pdrop2
         leas  1,s                    discard mode
PB_drop  leas  1,s                    discard saved byte
         bra   PB_pcount
PB_phdr  puls  a                      restore byte
         lbsr  HdrFeedByte
PB_pcount
         ldd   plen,u
         subd  #1
         std   plen,u
         bne   PB_ret
         clr   state,u
         lbsr  DispatchFrame
PB_ret   rts

* state 0: scan for "+IPD," and also for "CLOSED" (ESP disconnect notice)
PB_scan  pshs  a
         lbsr  ChkClose
         puls  a
         ldb   match,u
         leax  ipdstr,pcr
         cmpa  b,x
         bne   PB_sm
         incb
         cmpb  #5
         beq   PB_frame
         stb   match,u
         rts
PB_sm    clrb
         cmpa  #'+
         bne   PB_sm0
         ldb   #1
PB_sm0   stb   match,u
         rts

* ChkClose: scan for "<N>,CLOSED" sequence.  Remember any decimal digit
* we see in the scan state - that is the link ID that ESP will report
* closed.  When "CLOSED" matches, hangup paths[lastDig].
ChkClose pshs  a                  remember byte; we trash A below
         suba  #'0
         cmpa  #NLINKS
         bhs   CC_notdig
         sta   lastDig,u
CC_notdig
         puls  a
         ldb   closeMt,u
         leax  closeStr,pcr
         cmpa  b,x
         bne   CC_reset
         incb
         cmpb  #closeStrL
         beq   CC_fire
         stb   closeMt,u
         rts
CC_reset clrb
         cmpa  #'C
         bne   CC_sto
         incb
CC_sto   stb   closeMt,u
         rts
CC_fire  clr   closeMt,u
         lda   lastDig,u
         cmpa  #NLINKS
         bhs   CC_ret             no valid link ID recorded
         lbsr  ReleaseLink
         lda   #$FF
         sta   lastDig,u
CC_ret   rts
PB_frame clr   match,u
         lda   #1
         sta   state,u
         rts

* state 1: parse connection id digit(s) until ','
PB_id    cmpa  #',
         beq   PB_id_done
         suba  #'0
         cmpa  #NLINKS
         bhs   PB_id_r            out of range - ignore
         sta   curLink,u
PB_id_r  rts
PB_id_done lda   #2
         sta   state,u
         ldd   #0
         std   plen,u
         rts

* state 2: read decimal length until ':'
PB_len   cmpa  #':
         beq   PB_le
         suba  #'0
         ldx   plen,u
         lbsr  Mul10Add
         stx   plen,u
         rts
PB_le    lda   #3
         sta   state,u
         ldd   #0
         std   inlen,u
         rts

* === DispatchFrame: route a completed +IPD frame by linkMode[curLink] ===
*   UNBOUND   - sniff for "WTUP"; on match transition to FILE_HDR and
*               feed remaining bytes to the header parser. On miss,
*               allocate a tnPool slot, become TELNET, push filtered.
*   TELNET    - filter and SS.WtPush inbuf to linkPath[curLink].
*   FILE_HDR  - per-byte work already happened in PB_payload; nothing
*               to do at frame end except clear inbuf.
*   FILE_BODY - flush inbuf via FlushBody, which writes to the open
*               file and tracks linkRem; on completion sends status
*               and closes the link.
DispatchFrame
         ldb   curLink,u
         cmpb  #NLINKS
         lbhs  DF_clr
         leax  linkMode,u
         lda   b,x
         cmpa  #LM_TELNET
         lbeq  DF_telnet
         cmpa  #LM_FILEBODY
         lbeq  DF_fbody
         cmpa  #LM_FILEHDR
         lbeq  DF_clr
* LM_UNBOUND - sniff
         ldd   inlen,u
         cmpd  #magicLen
         lblo  DF_btn
         leax  inbuf,u
         leay  magicStr,pcr
         ldb   #magicLen
DF_smcmp lda   ,x+
         cmpa  ,y+
         bne   DF_btn
         decb
         bne   DF_smcmp
* Magic matched - check parser availability
         lda   fhLink,u
         cmpa  #$FF
         bne   DF_busy
         ldb   curLink,u
         stb   fhLink,u
         leax  linkMode,u
         lda   #LM_FILEHDR
         sta   b,x
         lda   #FH_NEEDLEN
         sta   fhState,u
         clr   fhNameOf,u
         clr   fhSizeOf,u
         ldd   #0
         std   fhSizeHi,u
         std   fhSizeLo,u
* Feed bytes after the magic to the header parser
         ldd   inlen,u
         subd  #magicLen
         lbeq  DF_clr
         pshs  d                    remaining count (16-bit)
         leax  inbuf,u
         leax  magicLen,x
DF_hfd   lda   ,x+
         pshs  x
         lbsr  HdrFeedByte
         puls  x
         ldd   ,s                   remaining count (now at top after puls x)
         subd  #1
         std   ,s
         bne   DF_hfd
         leas  2,s
         lbra  DF_clr
DF_busy
         lda   #ST_BUSY
         lbsr  SendStatusAndClose
         lbra  DF_clr
DF_btn
         lbsr  AllocTnSlot          B = slot or $FF
         cmpb  #$FF
         lbeq  DF_noslot
* tnOwner[slot] = curLink
         leax  tnOwner,u
         abx
         lda   curLink,u
         sta   ,x
* linkPath[curLink] = tnPath[slot]
         leax  tnPath,u
         abx
         lda   ,x
         ldb   curLink,u
         leax  linkPath,u
         abx
         sta   ,x
* linkMode[curLink] = LM_TELNET
         ldb   curLink,u
         leax  linkMode,u
         abx
         lda   #LM_TELNET
         sta   ,x
         lbra  DF_telnet
DF_noslot
* No free telnet slot - close the link.
         lbsr  SendCipclose
         lbra  DF_clr

DF_telnet
         lbsr  FilterInbuf          collapses inbuf in place, updates inlen
         ldd   inlen,u
         lbeq  DF_clr
         ldb   curLink,u
         leax  linkPath,u
         abx
         lda   ,x
         lbeq  DF_clr               safety
         ldb   #SS.WtPush
         leax  inbuf,u
         ldy   inlen,u
         os9   I$SetStt
         lbra  DF_clr

DF_fbody
         lbsr  FlushBody
         lbra  DF_clr

DF_clr   ldd   #0
         std   inlen,u
         rts

* === FilterInbuf: drop bytes >=$80 and ==$0A in place ===
* in:  inbuf, inlen.  out: inlen reduced; inbuf compacted.
FilterInbuf
         ldd   #0
         pshs  d                    dst index (S+0..1)
         ldd   #0
         pshs  d                    src index (S+2..3)
FI_lp    ldd   2,s                  src
         cmpd  inlen,u
         bhs   FI_done
         leax  inbuf,u
         ldb   3,s
         abx
         lda   ,x
         cmpa  #$0A
         beq   FI_next
         cmpa  #$80
         bhs   FI_next
         leax  inbuf,u
         ldb   1,s
         abx
         sta   ,x
         ldd   0,s
         addd  #1
         std   0,s
FI_next  ldd   2,s
         addd  #1
         std   2,s
         bra   FI_lp
FI_done  ldd   0,s
         std   inlen,u
         leas  4,s
         rts

* === AllocTnSlot: find a free tnPool slot.  Returns B = slot or $FF. ===
AllocTnSlot
         clrb
AT_lp    cmpb  #NTNPOOL
         bhs   AT_none
         leax  tnOwner,u
         lda   b,x
         cmpa  #$FF
         beq   AT_got
         incb
         bra   AT_lp
AT_got   rts
AT_none  ldb   #$FF
         rts

* === ReleaseLink: tear down link state for the link in A on CLOSED. ===
*   TELNET    - free the tnPool slot, SS.WtHup the SCF path so the
*               shell gets S$HUP and tsmon respawns it cleanly.
*   FILE_HDR  - release the header parser.
*   FILE_BODY - close the open file (partial upload left on disk).
*               Release the header parser.
*   UNBOUND   - nothing.
* All cases: reset linkMode and magicMt for the link.
ReleaseLink
         pshs  a                    link
         leax  linkMode,u
         ldb   ,s
         lda   b,x
         cmpa  #LM_TELNET
         beq   RL_telnet
         cmpa  #LM_FILEBODY
         beq   RL_fbody
         cmpa  #LM_FILEHDR
         beq   RL_fhdr
         bra   RL_reset
RL_telnet
         leax  linkPath,u
         ldb   ,s
         abx
         lda   ,x
         beq   RL_telnet_free
         ldb   #SS.WtHup
         os9   I$SetStt
RL_telnet_free
* Find tnOwner[slot] == link, set to $FF
         clrb
RL_tof   cmpb  #NTNPOOL
         bhs   RL_reset
         leax  tnOwner,u
         lda   b,x
         cmpa  ,s
         bne   RL_tof_n
         lda   #$FF
         sta   ,x
         bra   RL_reset
RL_tof_n incb
         bra   RL_tof
RL_fbody
         leax  linkPath,u
         ldb   ,s
         abx
         lda   ,x
         beq   RL_fhdr
         os9   I$Close
RL_fhdr
         lda   fhLink,u
         cmpa  ,s
         bne   RL_reset
         lda   #$FF
         sta   fhLink,u
RL_reset ldb   ,s
         leax  linkMode,u
         abx
         lda   #LM_UNBOUND
         sta   ,x
         ldb   ,s
         leax  linkPath,u
         abx
         clr   ,x
         ldb   ,s
         leax  magicMt,u
         abx
         clr   ,x
         puls  a,pc

* === HdrFeedByte: feed one byte (A) to the file-header parser. ===
* Substates: FH_NEEDLEN -> FH_NAME -> FH_SIZE.  When the 4-byte
* sizeBE completes, open the destination file, transition the owning
* link to FILE_BODY, and store the path in linkPath[].
HdrFeedByte
         pshs  a
         ldb   fhState,u
         cmpb  #FH_NEEDLEN
         beq   HF_len
         cmpb  #FH_NAME
         beq   HF_name
* FH_SIZE
         puls  a
         ldb   fhSizeOf,u
         cmpb  #4
         bhs   HF_ret               extra bytes, shouldn't happen
         leax  fhSizeHi,u
         abx
         sta   ,x
         inc   fhSizeOf,u
         lda   fhSizeOf,u
         cmpa  #4
         lblo  HF_ret
         lbsr  HdrOpen
HF_ret   rts

HF_len   puls  a
         tsta
         beq   HF_badname
         cmpa  #FHNAMEMX
         bhi   HF_badname
         sta   fhNameLn,u
         clr   fhNameOf,u
         ldb   #FH_NAME
         stb   fhState,u
         rts
HF_badname
         lda   #ST_BADNAME
         lbsr  SendStatusAndClose
         lda   #$FF
         sta   fhLink,u
         clr   fhState,u
         rts

HF_name  puls  a
         ldb   fhNameOf,u
         leax  fhName,u
         abx
         sta   ,x
         inc   fhNameOf,u
         lda   fhNameOf,u
         cmpa  fhNameLn,u
         blo   HF_nm_ret
* name complete - $0D-terminate
         ldb   fhNameOf,u
         leax  fhName,u
         abx
         lda   #$0D
         sta   ,x
         ldb   #FH_SIZE
         stb   fhState,u
         clr   fhSizeOf,u
HF_nm_ret rts

* === HdrOpen: header is fully parsed; open the destination file ===
* Reject if high 16 bits of sizeBE are nonzero (>64KB-1).  Reject if
* sizeBE is zero (we treat as "nothing to write" but still create the
* file and reply OK; could allow empty files trivially).
HdrOpen
         ldd   fhSizeHi,u
         beq   HO_size_ok
         lda   #ST_TOOBIG
         bra   HO_fail
HO_size_ok
* Try I$Create for new files; fall back to I$Open+truncate semantics
* on "file exists" error by deleting + recreating.
         leax  fhName,u
         lda   #UPDAT.
         ldb   #$03                 attr: single user r/w
         os9   I$Create
         bcc   HO_have_path
* Try delete + recreate (handles existing file case)
         leax  fhName,u
         os9   I$Delete
         leax  fhName,u
         lda   #UPDAT.
         ldb   #$03
         os9   I$Create
         bcc   HO_have_path
         lda   #ST_OPEN
         bra   HO_fail
HO_have_path
         pshs  a                    open path
         ldb   fhLink,u
         cmpb  #NLINKS
         lbhs  HO_fail_pop
         leax  linkPath,u
         abx
         puls  a
         sta   ,x
         ldb   fhLink,u
         leax  linkMode,u
         abx
         lda   #LM_FILEBODY
         sta   ,x
* linkRem[link*2] = fhSizeLo
         ldb   fhLink,u
         aslb
         leax  linkRem,u
         abx
         ldd   fhSizeLo,u
         std   ,x
* Check for zero-size: send OK immediately
         ldd   fhSizeLo,u
         bne   HO_ok
         lbsr  FinishUpload
         rts
HO_ok    rts
HO_fail_pop leas 1,s
         lda   #ST_OPEN
HO_fail  pshs  a
         puls  a
         lbsr  SendStatusAndClose
         lda   #$FF
         sta   fhLink,u
         clr   fhState,u
         ldb   curLink,u
         leax  linkMode,u
         abx
         lda   #LM_UNBOUND
         sta   ,x
         rts

* === FlushBody: write inbuf (inlen bytes) to linkPath[curLink], ===
* decrement linkRem.  If linkRem hits zero, FinishUpload.  On
* I$Write error, send ST_WRITE and close.
FlushBody
         ldd   inlen,u
         beq   FB_ret
         ldb   curLink,u
         leax  linkPath,u
         abx
         lda   ,x
         lbeq  FB_clr               safety: no open file
         leax  inbuf,u
         ldy   inlen,u
         os9   I$Write
         bcs   FB_werr
* linkRem[link*2] -= inlen
         ldb   curLink,u
         aslb
         leax  linkRem,u
         abx
         ldd   ,x
         subd  inlen,u
         std   ,x
         beq   FB_done
FB_clr   ldd   #0
         std   inlen,u
FB_ret   rts
FB_done  ldd   #0
         std   inlen,u
         lbsr  FinishUpload
         rts
FB_werr  lda   #ST_WRITE
         lbsr  SendStatusAndClose
         ldb   curLink,u
         leax  linkPath,u
         abx
         lda   ,x
         beq   FB_werr_done
         os9   I$Close
FB_werr_done
         ldb   curLink,u
         leax  linkPath,u
         abx
         clr   ,x
         ldb   curLink,u
         leax  linkMode,u
         abx
         lda   #LM_UNBOUND
         sta   ,x
         lda   #$FF
         sta   fhLink,u
         clr   fhState,u
         lbra  FB_clr

* === FinishUpload: payload complete - close file, send ST_OK, ===
* close the TCP link, and release per-link state.
FinishUpload
         ldb   curLink,u
         leax  linkPath,u
         abx
         lda   ,x
         beq   FU_after_close
         os9   I$Close
FU_after_close
         ldb   curLink,u
         leax  linkPath,u
         abx
         clr   ,x
         lda   #ST_OK
         lbsr  SendStatusAndClose
         ldb   curLink,u
         leax  linkMode,u
         abx
         lda   #LM_UNBOUND
         sta   ,x
         lda   #$FF
         sta   fhLink,u
         clr   fhState,u
         rts

* === SendStatusAndClose: ===
* Send the single status byte in A back to curLink via AT+CIPSEND=N,1,
* then AT+CIPCLOSE=N.
SendStatusAndClose
         sta   statByte,u
         lda   curLink,u
         sta   sendLink,u
         ldd   #1
         std   outlen,u
* DoCipsend reads outbuf - copy statByte into outbuf[0].
         lda   statByte,u
         sta   outbuf,u
         lbsr  DoCipsend
         lbsr  SendCipclose
         rts

* === SendCipclose: send AT+CIPCLOSE=<curLink>\r\n ===
SendCipclose
         leax  clsCmd,pcr
         ldb   #clsCmdL
SC_cmd   lda   ,x+
         lbsr  PutW
         decb
         bne   SC_cmd
         lda   curLink,u
         adda  #'0
         lbsr  PutW
         lda   #$0D
         lbsr  PutW
         lda   #$0A
         lbsr  PutW
         rts

* === DoCipsend: send outbuf (outlen bytes) via AT+CIPSEND=0,<n> ===
* While waiting for the '>' prompt, keep feeding RX bytes through the
* parser so a +IPD frame that arrives during the handshake isn't lost.
DoCipsend
* Drain any leftover ESP output (e.g. async "0,CONNECT" / "SEND OK"
* from previous round) so our DC_wait isn't busy parsing stale bytes
* while we wait for the real '>' prompt.
DC_pre   lda   >WFCTL
         bita  #RDAVAIL
         beq   DC_pre_done
         lda   >WFDAT
         lbsr  ParseByte
         bra   DC_pre
DC_pre_done
         leax  cipcmd,pcr
         ldb   #cipcmdL
DC_cmd   lda   ,x+
         lbsr  PutW
         decb
         bne   DC_cmd
         lda   sendLink,u           link ID digit
         adda  #'0
         lbsr  PutW
         lda   #',
         lbsr  PutW
         ldx   outlen,u
         lbsr  PutDec
         lda   #$0D
         lbsr  PutW
         lda   #$0A
         lbsr  PutW
* Wait for the '>' prompt.  Give up after a few seconds of ESP
* silence/errors; satisfy the AT+CIPSEND data mode by sending NULs so
* ESP returns to command mode, then sleep to let it recover.
DC_wait  ldx   #$0080               max 128 iterations (~2s worst case)
DC_wlp   lbsr  TryGetW
         bcs   DC_wno
         cmpa  #'>
         beq   DC_go
         lbsr  ParseByte
         bra   DC_wnext
DC_wno   pshs  x
         ldx   #1
         os9   F$Sleep
         puls  x
DC_wnext leax  -1,x
         lbne  DC_wlp
DC_giveup
         pshs  x,a,b
         leax  msgTimeout,pcr
         ldy   #msgTimeoutL
         lbsr  Dbg
         puls  x,a,b
         ldd   outlen,u
         pshs  d
DC_fill  ldd   ,s
         beq   DC_filled
         clra
         lbsr  PutW
         ldd   ,s
         subd  #1
         std   ,s
         bra   DC_fill
DC_filled leas 2,s
         pshs  x
         ldx   #60
         os9   F$Sleep
         puls  x
         rts
DC_go    ldd   outlen,u
         pshs  d
         leax  outbuf,u
DC_lp    ldd   ,s
         beq   DC_done
         lda   ,x+
         pshs  x
         lbsr  PutW
         puls  x
         ldd   ,s
         subd  #1
         std   ,s
         bra   DC_lp
* Drain ESP responses after the payload until we see the terminating
* LF of "SEND OK\r\n" (or give up after ~1s).  Without this we race
* the next CIPSEND in before ESP has finished processing the last one,
* and the second AT+CIPSEND comes back as ERROR.
DC_done  leas  2,s
         ldx   #$0200
DC_ok    lbsr  TryGetW
         bcs   DC_ok_no
         cmpa  #$0A
         beq   DC_ret
         lbsr  ParseByte
         bra   DC_oknext
DC_ok_no pshs  x
         ldx   #1
         os9   F$Sleep
         puls  x
DC_oknext leax  -1,x
         bne   DC_ok
DC_ret   pshs  x
         ldx   #3
         os9   F$Sleep
         puls  x
         rts

* === Mul10Add: X = X*10 + A ===
Mul10Add pshs  a
         tfr   x,d
         aslb
         rola
         pshs  d
         aslb
         rola
         aslb
         rola
         addd  ,s++
         addb  ,s+
         adca  #0
         tfr   d,x
         rts

* === TryGetW: non-blocking poll.  Returns A=byte / carry clear if a
*     byte was available; carry set otherwise. ===
TryGetW  lda   >WFCTL
         bita  #RDAVAIL
         beq   TGW_no
         lda   >WFDAT
         andcc #^Carry
         rts
TGW_no   orcc  #Carry
         rts

* === GetW: read one WiFi byte (blocks, signal-safe) ===
GetW     pshs  x,b
GW_poll  lda   >WFCTL
         bita  #RDAVAIL
         bne   GW_got
         ldx   #SPIN
GW_spin  lda   >WFCTL
         bita  #RDAVAIL
         bne   GW_got
         leax  -1,x
         bne   GW_spin
         ldx   #1
         os9   F$Sleep
         bra   GW_poll
GW_got   lda   >WFDAT
         puls  x,b
         rts

* === PutW: send byte A to the WiFi TX FIFO.  Preserves A and B
*     (the delay loop's `ldb #32` would otherwise trash callers' counters). ===
PutW     pshs  a,b
PW_poll  lda   >WFCTL
         bita  #WRFULL
         bne   PW_poll
         puls  a
         sta   >WFDAT
         ldb   #32
PW_dly   decb
         bne   PW_dly
         puls  b
         rts

* === PutDec: emit X as decimal ASCII via PutW ===
PutDec   clr   ndig,u
PD_div   lbsr  Div10
         addb  #'0
         pshs  b
         inc   ndig,u
         cmpx  #0
         bne   PD_div
PD_emit  puls  a
         lbsr  PutW
         dec   ndig,u
         bne   PD_emit
         rts

Div10    pshs  y
         ldy   #0
D10_lp   cmpx  #10
         blo   D10_done
         leax  -10,x
         leay  1,y
         bra   D10_lp
D10_done tfr   x,d
         tfr   y,x
         puls  y
         rts

* === Dbg: write Y bytes at X to stdout ===
Dbg      pshs  x,y,a,b,u
         lda   #1
         os9   I$Write
         puls  x,y,a,b,u,pc

* === DbgDec: print X as 4-char hex to stdout ===
DbgDec   pshs  x,a,b
         pshs  x                  ; push X onto stack (high:low)
         puls  a                  ; A = high byte of X
         lbsr  DbgHByte
         puls  a                  ; A = low byte of X
         lbsr  DbgHByte
         puls  x,a,b,pc

DbgHByte pshs  a
         lsra
         lsra
         lsra
         lsra
         lbsr  DbgNib
         puls  a
         anda  #$0F
DbgNib   adda  #'0
         cmpa  #'9
         bls   DN_ok
         adda  #7
DN_ok    sta   dbgbyte,u
         pshs  a,b,x,y
         leax  dbgbyte,u
         ldy   #1
         lda   #1
         os9   I$Write
         puls  a,b,x,y,pc

DbgNL    pshs  a,b,x,y
         leax  crlfMsg,pcr
         ldy   #crlfMsgL
         lda   #1
         os9   I$Write
         puls  a,b,x,y,pc

         emod
eom      equ   *
         end
