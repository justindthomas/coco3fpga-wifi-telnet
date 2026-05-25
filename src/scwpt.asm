********************************************************************
* scwpt - pseudo-terminal driver for the WiFi telnet bridge
*
* Provides /wt as an SCF terminal backed by two in-memory ring buffers
* in the device's static storage:
*   m2s (master -> slave): bytes pushed by wtbridge via SS.WtPush,
*       consumed by the shell as terminal input (driver Read).
*   s2m (slave -> master): bytes the shell writes as terminal output
*       (driver Write), drained by wtbridge via SS.WtPull.
*
* The driver itself does no protocol parsing, no IRQ work, and no
* tight spinning - blocking Read/Write yield with F$Sleep(1) and check
* P$Signal each iteration. SCF above the driver handles all of the
* terminal semantics (echo, line editing, prompt rendering, etc.).
*
* Custom SCF status codes:
*   SS.WtPush ($80, I$SetStt): caller's X = source buffer (caller's
*       task memory), caller's Y = byte count. Up to Y bytes are
*       copied into m2s and the actual pushed count is stored back
*       in the caller's R$Y. Stops early if m2s fills.
*   SS.WtPull ($81, I$GetStt): caller's X = dest buffer, caller's
*       Y = max byte count. Up to min(Y, s2mCnt) bytes are popped
*       from s2m into the buffer; actual count is stored in caller's
*       R$Y (zero is fine - just try again later).

         nam   scwpt
         ttl   pseudo-terminal driver

         ifp1
         use   defsfile
         endc

WPSize    equ   256             ring buffer size (8-bit head/tail wraps cleanly)
SS.WtPush equ   $80
SS.WtPull equ   $81
SS.WtHup  equ   $82             send S$HUP to the path's owner

rev      set   0
edition  set   1

         mod   eom,name,Drivr+Objct,ReEnt+rev,ModEntry,MemSize
         fcb   UPDAT.

name     fcs   /scwpt/
         fcb   edition

ModEntry lbra  Init
         lbra  Read
         lbra  Write
         lbra  GetStt
         lbra  SetStt
         lbra  Term

         org   V.SCF
m2sBuf   rmb   WPSize
m2sHd    rmb   1
m2sTl    rmb   1
m2sCnt   rmb   2
s2mBuf   rmb   WPSize
s2mHd    rmb   1
s2mTl    rmb   1
s2mCnt   rmb   2
SSigID   rmb   1                  PID requesting send-signal-on-data
SSigSg   rmb   1                  signal number to send
SHupID   rmb   1                  PID to receive S$HUP on SS.WtHup
MemSize  equ   .

* === Init: U = device static storage ===
* Wipe all of our static area so subsequent reads/pulls don't see
* uninitialized garbage as buffer state.
Init     leax  V.SCF,u
         ldd   #MemSize-V.SCF
Iz_lp    clr   ,x+
         subd  #1
         bne   Iz_lp
         clrb
         rts

* === Read: return one byte from m2s in A.  Block while empty.
*     SCF acquires V.BUSY before dispatching, but our blocking sleep
*     would deadlock anyone else trying to do I/O on /wt (especially
*     wtbridge's SS.WtPush).  So we drop V.BUSY before F$Sleep and
*     reclaim it before returning. ===
Read     pshs  y
         lda   SSigID,u            send-signal-on-data set up?
         lbne  RdNotRdy            yes - return not ready, caller sleeps
RdLoop   ldx   >D.Proc
         ldb   P$Signal,x
         lbne  RdSig
         ldd   m2sCnt,u
         bne   RdHave
         clr   V.BUSY,u           release the device while we sleep
         ldx   #1
         os9   F$Sleep
         bra   RdLoop
RdHave   ldx   >D.Proc            data available - reclaim V.BUSY
         lda   P$ID,x
         sta   V.BUSY,u
         ldd   m2sCnt,u
         subd  #1
         std   m2sCnt,u
         ldb   m2sTl,u
         leax  m2sBuf,u
         abx
         lda   ,x
         incb
         stb   m2sTl,u
         puls  y
         clrb
         rts
RdSig    puls  y
         comb
         ldb   #E$NotRdy
         rts
RdNotRdy puls  y
         comb
         ldb   #E$NotRdy
         rts

* === Write: push A into s2m.  Block while full.  Same V.BUSY-yield
*     pattern as Read so wtbridge's SS.WtPull can drain while we wait. ===
Write    pshs  y,a
WrLoop   ldx   >D.Proc
         ldb   P$Signal,x
         lbne  WrSig
         ldd   s2mCnt,u
         cmpd  #WPSize
         lblo  WrHave
         clr   V.BUSY,u           release while we wait for drain
         ldx   #1
         os9   F$Sleep
         bra   WrLoop
WrHave   ldx   >D.Proc            slot opened up - reclaim V.BUSY
         lda   P$ID,x
         sta   V.BUSY,u
         ldb   s2mHd,u
         leax  s2mBuf,u
         abx
         lda   ,s              saved byte (pshs y,a: A is at the top)
         sta   ,x
         incb
         stb   s2mHd,u
         ldd   s2mCnt,u
         addd  #1
         std   s2mCnt,u
         puls  y,a
         clrb
         rts
WrSig    puls  y,a
         comb
         ldb   #E$PrcAbt
         rts

* === GetStt: SS.WtPull, SS.ScSiz (so dir/etc lay out columns sanely),
*     or default no-op ===
GetStt   cmpa  #SS.WtPull
         lbeq  WtPull
         cmpa  #SS.ScSiz
         lbeq  DoScSiz
         clrb
         rts

* SS.ScSiz: return screen size from the descriptor's IT.COL / IT.ROW.
DoScSiz  ldx   PD.RGS,y
         ldu   PD.DEV,y
         ldu   V$DESC,u
         clra
         ldb   IT.COL,u
         std   R$X,x
         ldb   IT.ROW,u
         std   R$Y,x
         clrb
         rts

* === SetStt: SS.WtPush, SS.SSig, SS.Relea, SS.WtHup, SS.Close,
*     or default no-op ===
SetStt   cmpa  #SS.WtPush
         lbeq  WtPush
         cmpa  #SS.SSig
         lbeq  DoSSig
         cmpa  #SS.Relea
         lbeq  DoRelea
         cmpa  #SS.WtHup
         lbeq  DoHup
         cmpa  #SS.Close
         lbeq  Init                 reuse the wipe-all initializer
         clrb
         rts

* SS.WtHup: F$Send S$HUP to the path's owner so it can clean up
* (we use this when wtbridge sees ESP's "0,CLOSED" disconnect notice).
DoHup    lda   SHupID,u
         beq   Hup_done
         ldb   #S$HUP
         pshs  u,y
         os9   F$Send
         puls  u,y
         clr   SHupID,u
         clr   SSigID,u
Hup_done clrb
         rts

* SS.SSig: arrange to F$Send a signal to caller when data ready in m2s.
* Caller's R$X low byte = signal code.  If m2s already has data, send
* the signal immediately.  We also remember the caller in SHupID so a
* later SS.WtHup can hangup whoever owns the path.
DoSSig   ldx   PD.RGS,y
         ldb   R$X+1,x             signal number from caller's X (low byte)
         lda   PD.CPR,y            caller's process ID
         sta   SHupID,u            remember owner for hangup
         pshs  d                   save PID:signal across m2s check
         ldx   m2sCnt,u
         lbeq  SSig_set            no data - register the trap
         puls  d
         os9   F$Send              data already here - signal now
         clrb
         rts
SSig_set puls  d
         std   SSigID,u            stored as PID(high):signal(low)
         clrb
         rts

* SS.Relea: clear the signal trap and hangup-owner if it's ours.
DoRelea  lda   PD.CPR,y
         cmpa  SSigID,u
         bne   Relea_ex
         clr   SSigID,u
         clr   SHupID,u
Relea_ex clrb
         rts

* === WtPush: master pushes caller's X[0..Y-1] -> m2s ===
* Y on entry = path desc.  Returns caller's R$Y = bytes actually pushed.
WtPush   ldx   PD.RGS,y
         pshs  x,y             0,s=reg-stack ptr, 2,s=path desc
         ldd   #0
         pshs  d               0,s=pushed count, 2,s=reg stack, 4,s=path desc
WPp_lp   ldx   2,s
         ldd   R$Y,x
         lbeq  WPp_done         caller's max exhausted
         ldd   m2sCnt,u
         cmpd  #WPSize
         lbeq  WPp_done         m2s full, stop here
         ldy   R$X,x            Y = caller's source addr (next byte)
         ldx   >D.Proc
         ldb   P$Task,x         B = caller's task
         tfr   y,x              X = caller's addr
         pshs  u,y              F$LDABX may clobber U / Y
         os9   F$LDABX          A = byte at addr X in task B
         puls  u,y
         ldb   m2sHd,u
         leax  m2sBuf,u
         abx
         sta   ,x               m2sBuf[head] = byte
         incb
         stb   m2sHd,u
         ldd   m2sCnt,u
         addd  #1
         std   m2sCnt,u
         ldx   2,s              X = reg stack
         ldd   R$X,x
         addd  #1
         std   R$X,x            advance caller's R$X
         ldd   R$Y,x
         subd  #1
         std   R$Y,x            decrement caller's R$Y
         ldd   ,s
         addd  #1
         std   ,s               pushed++
         lbra  WPp_lp
WPp_done ldx   2,s
         ldd   ,s
         std   R$Y,x            caller's R$Y <- pushed count
         leas  2,s
         puls  x,y
* If a process armed SS.SSig, fire the signal now that m2s has data.
         lda   SSigID,u
         beq   WPp_ret
         ldd   m2sCnt,u
         lbeq  WPp_ret             we didn't actually push anything
         lda   SSigID,u
         ldb   SSigSg,u
         clr   SSigID,u            one-shot
         pshs  u,y
         os9   F$Send
         puls  u,y
WPp_ret  clrb
         rts

* === WtPull: master pulls s2m -> caller's X (up to Y bytes) ===
WtPull   ldx   PD.RGS,y
         pshs  x,y
         ldd   #0
         pshs  d                0,s=pulled count, 2,s=reg stack, 4,s=path desc
WPL_lp   ldx   2,s
         ldd   R$Y,x
         lbeq  WPL_done          caller's max exhausted
         ldd   s2mCnt,u
         lbeq  WPL_done          s2m empty - done
         subd  #1
         std   s2mCnt,u
         ldb   s2mTl,u
         leax  s2mBuf,u
         abx
         lda   ,x                A = byte to deliver
         incb
         stb   s2mTl,u
         ldx   2,s
         ldy   R$X,x             Y = caller's dest addr
         pshs  a                 save the byte
         ldx   >D.Proc
         ldb   P$Task,x          B = caller's task
         puls  a
         tfr   y,x               X = caller's addr
         pshs  u,y               F$STABX may clobber U / Y
         os9   F$STABX           store A at addr X in task B
         puls  u,y
         ldx   2,s
         ldd   R$X,x
         addd  #1
         std   R$X,x
         ldd   R$Y,x
         subd  #1
         std   R$Y,x
         ldd   ,s
         addd  #1
         std   ,s                pulled++
         lbra  WPL_lp
WPL_done ldx   2,s
         ldd   ,s
         std   R$Y,x             caller's R$Y <- pulled count
         leas  2,s
         puls  x,y
         clrb
         rts

* === Term: nothing to release ===
Term     clrb
         rts

         emod
eom      equ   *
         end
