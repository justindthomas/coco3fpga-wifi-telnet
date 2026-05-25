********************************************************************
* wtbridge - WiFi <-> /wt bidirectional bridge (v4)
*
* Single user-space process. Owns the WiFi FIFO ($FF6C/$FF6D) and the
* master side of the scwpt pseudo-terminal (/wt).  Each main-loop
* iteration:
*
*   1. SS.WtPull /wt's s2m into outbuf.  If anything came back,
*      send it to the WiFi as one AT+CIPSEND=0,<n> batch.
*   2. Drain whatever is sitting in the WiFi RX FIFO; feed every byte
*      through the +IPD,<id>,<len>:<payload> parser.  On a complete
*      frame, SS.WtPush the payload to /wt's m2s.
*   3. If neither direction had work this iteration, F$Sleep(1) tick.
*
* The shell on /wt sees a normal SCF terminal - SCF handles echo, line
* editing, prompt rendering, etc., so there is zero terminal logic in
* user space.  ESP must be in TCP server mode (AT+CIPMUX=1 /
* AT+CIPSERVER=1,23); connection id is assumed 0.

         nam   wtbridge
         ttl   WiFi <-> /wt bidirectional bridge

         ifp1
         use   defsfile
         endc

tylg     set   Prgrm+Objct
atrv     set   ReEnt+rev
rev      set   $00
edition  set   4

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
NLINKS   equ   3                 simultaneous TCP clients we can route

         mod   eom,name,tylg,atrv,start,size

         org   0
paths    rmb   NLINKS            OS-9 path numbers for /wt, /wt1, /wt2
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
         clr   paths,u
         clr   paths+1,u
         clr   paths+2,u
         leax  wt0name,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   paths,u
         leax  wt1name,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   paths+1,u
         leax  wt2name,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   paths+2,u
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

* --- 1) for each link 0..NLINKS-1: drain its s2m and CIPSEND back. ---
         clr   iLink,u
ML_drain ldb   iLink,u
         cmpb  #NLINKS
         lbhs  ML_drainEnd
         leax  paths,u
         lda   b,x
         beq   ML_drainNext       link not open
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
         lda   iLink,u
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
         cmpb  #NLINKS
         bhs   EX_done
         leax  paths,u
         lda   b,x
         beq   EX_next
         os9   I$Close
EX_next  inc   iLink,u
         bra   EX_lp
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
         cmpa  #$0A                   drop LF (telnet sends CR+LF)
         beq   PB_pyn
         cmpa  #$80                   drop telnet IAC / 8-bit bytes
         bhs   PB_pyn
         pshs  a                      save byte; ldd below clobbers A
         ldd   inlen,u
         cmpd  #INMAX
         bhs   PB_drop
         leax  inbuf,u
         leax  d,x
         puls  a
         sta   ,x
         ldd   inlen,u
         addd  #1
         std   inlen,u
         bra   PB_pyn
PB_drop  leas  1,s                    buffer full - discard saved byte
PB_pyn   ldd   plen,u
         subd  #1
         std   plen,u
         bne   PB_ret
         clr   state,u
         lbsr  PushFrame
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
         leax  paths,u
         ldb   a,x
         beq   CC_ret             link not open
         tfr   b,a
         ldb   #SS.WtHup
         os9   I$SetStt
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

* === PushFrame: SS.WtPush inbuf (inlen bytes) into /wt's m2s ===
PushFrame
         ldd   inlen,u
         beq   PF_done
         ldb   curLink,u
         cmpb  #NLINKS
         bhs   PF_done            invalid link - drop frame
         leax  paths,u
         lda   b,x
         beq   PF_done            link not open
         ldb   #SS.WtPush
         leax  inbuf,u
         ldy   inlen,u
         os9   I$SetStt
PF_done  ldd   #0
         std   inlen,u
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
