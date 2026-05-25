********************************************************************
* wifi - send a command to the CoCo3FPGA WiFi (ESP8266) and show the
*        reply
*
* WiFi FIFO interface at $FF6C/$FF6D (v5.0 bitstream):
*   $FF6C write = control : bit 7 IRQ enable, bits 1-0 baud rate
*   $FF6C read  = status  : bit 1 read data available, bit 0 write FIFO full
*   $FF6D       = data    : read pops RX FIFO, write pushes TX FIFO
*
* Uses baud setting 0 - the rate confirmed to match the ESP8266.
* Sends the argument string terminated with CR+LF, then prints the
* reply until the line goes quiet.
*
* Usage:  wifi AT          wifi AT+GMR          wifi AT+CIFSR

         nam   wifi
         ttl   CoCo3FPGA WiFi terminal

         ifp1
         use   defsfile
         endc

tylg     set   Prgrm+Objct
atrv     set   ReEnt+rev
rev      set   $01
edition  set   2

WFCTL    equ   $FF6C          control (write) / status (read)
WFDAT    equ   $FF6D          data register
WRFULL   equ   %00000001      status: write FIFO full
RDAVAIL  equ   %00000010      status: read data available
SPIN     equ   $4000          inter-byte poll window
IDLEQUIT equ   12             quiet periods before stopping

         mod   eom,name,tylg,atrv,start,size

         org   0
parmptr  rmb   2              command-line parameter pointer
idle     rmb   1              quiet-period counter
onebyte  rmb   1              one-byte I/O scratch
         rmb   400            stack
size     equ   .

name     fcs   /wifi/
         fcb   edition

start    pshs  x              (X = parameter pointer on entry)
         tfr   dp,a
         clrb
         tfr   d,u            U = data area base
         puls  x
         stx   parmptr,u

         clra                 control: IRQ off, baud 0 (known-good rate)
         sta   >WFCTL

DrainLp  lda   >WFCTL          drain any stale RX FIFO bytes
         bita  #RDAVAIL
         beq   DrainOk
         lda   >WFDAT
         bra   DrainLp

DrainOk  ldx   parmptr,u       transmit the parameter string
SkipSp   lda   ,x+
         cmpa  #$20
         beq   SkipSp
         leax  -1,x
SendLp   lda   ,x+
         cmpa  #$0D
         beq   SendCR
         lbsr  PutW
         bra   SendLp
SendCR   lda   #$0D            terminate the command with CR + LF
         lbsr  PutW
         lda   #$0A
         lbsr  PutW

         clr   idle,u          receive the reply until the line is quiet
RxLoop   ldy   #SPIN
RxSpin   lda   >WFCTL
         bita  #RDAVAIL
         bne   RxByte
         leay  -1,y
         bne   RxSpin
         lda   idle,u
         inca
         sta   idle,u
         cmpa  #IDLEQUIT
         bhs   RxDone
         ldx   #2
         os9   F$Sleep
         bra   RxLoop
RxByte   lda   >WFDAT
         lbsr  PutC
         clr   idle,u
         bra   RxLoop

RxDone   lda   #$0D            tidy trailing newline
         lbsr  PutC
         clrb
         os9   F$Exit

* write Y bytes at X to standard output
Wr1      lda   #1
         os9   I$Write
         rts

* emit the single character in A to standard output
PutC     sta   onebyte,u
         leax  onebyte,u
         ldy   #1
         bra   Wr1

* push the byte in A into the WiFi TX FIFO (waits while full).  The
* short post-write spin gives the FPGA time to update WRFULL before
* the next PutW polls it - without that, at 25 MHz CPU we'd read a
* stale "not full" and clobber the FIFO.
PutW     pshs  a
PutWf    lda   >WFCTL
         bita  #WRFULL
         bne   PutWf
         puls  a
         sta   >WFDAT
         ldb   #32
PWdly    decb
         bne   PWdly
         rts

         emod
eom      equ   *
         end
