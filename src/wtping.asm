********************************************************************
* wtping - round-trip test for the scwpt pseudo-terminal driver
*
* Pushes its parameter string to /wt's m2s (SS.WtPush), waits half a
* second so anything listening (e.g. tsmon -> login on /wt) can act,
* then pulls whatever is in s2m (SS.WtPull) and writes it to stdout.
*
* Usage:    wtping <text>          (text goes to the slave as input)

         nam   wtping
         ttl   scwpt round-trip test

         ifp1
         use   defsfile
         endc

tylg     set   Prgrm+Objct
atrv     set   ReEnt+rev
rev      set   $00
edition  set   1

SS.WtPush equ  $80
SS.WtPull equ  $81

         mod   eom,name,tylg,atrv,start,size

         org   0
parmptr  rmb   2
parmlen  rmb   2
path     rmb   1
pullbuf  rmb   256
         rmb   200
size     equ   .

name     fcs   /wtping/
         fcb   edition

wtname   fcc   "/wt"
         fcb   $0D

start    pshs  a,b,x          save A:B (param length) and X (param ptr)
         tfr   dp,a
         clrb
         tfr   d,u
         puls  a,b,x
         stx   parmptr,u
         std   parmlen,u

         leax  wtname,pcr
         lda   #UPDAT.
         os9   I$Open
         lbcs  Exit
         sta   path,u

* --- push the parameter to m2s ---
         lda   path,u
         ldb   #SS.WtPush
         ldx   parmptr,u
         ldy   parmlen,u
         os9   I$SetStt
         lbcs  Close

* --- give the slave a moment to react ---
         ldx   #30
         os9   F$Sleep

* --- pull whatever's in s2m and write it to stdout ---
         lda   path,u
         ldb   #SS.WtPull
         leax  pullbuf,u
         ldy   #256
         os9   I$GetStt
         lbcs  Close
         cmpy  #0
         beq   Close
         leax  pullbuf,u
         lda   #1
         os9   I$Write

Close    lda   path,u
         os9   I$Close
Exit     clrb
         os9   F$Exit

         emod
eom      equ   *
         end
