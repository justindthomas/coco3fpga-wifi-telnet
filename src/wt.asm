********************************************************************
* WT - terminal descriptor for the wtbridge pseudo-terminal driver
*
* /wt is an SCF terminal whose "hardware" is a pair of in-memory ring
* buffers in the scwpt driver's static storage. The slave side (the
* shell) sees a normal SCF terminal with echo + autolf; wtbridge pumps
* WiFi <-> the master side via custom SS.WtPush / SS.WtPull status codes.
* There is no physical controller, so the address fields are zero.

         nam   WT
         ttl   wtbridge pseudo-terminal descriptor

         ifp1
         use   defsfile
         endc

tylg     set   Devic+Objct
atrv     set   ReEnt+rev
rev      set   $00

         mod   eom,name,tylg,atrv,mgrnam,drvnam

         fcb   UPDAT.     mode byte
         fcb   $00        extended controller address (no hw)
         fdb   $0000      physical controller address (no hw)
         fcb   initsize-*-1 initialisation table size
         fcb   DT.SCF     device type
         fcb   $00        case: 0=upper+lower
         fcb   $01        backspace: 1=bsp, sp, bsp
         fcb   $00        delete: 0=bsp over line
         fcb   $01        echo: 1=SCF echoes input back through Write
         fcb   $01        autolf: 1=CR -> CRLF on output
         fcb   $00        end of line null count
         fcb   $00        pause: 0=no end of page pause
         fcb   24         lines per page
         fcb   C$BSP      backspace character
         fcb   C$DEL      delete line character
         fcb   C$CR       end of record character
         fcb   C$EOF      end of file character
         fcb   C$RPRT     reprint line character
         fcb   C$RPET     duplicate last line character
         fcb   C$PAUS     pause character
         fcb   C$INTR     interrupt character
         fcb   C$QUIT     quit character
         fcb   C$BSP      backspace echo character
         fcb   $00        line overflow character (NUL = silent OVF)
         fcb   PARNONE    parity
         fcb   STOP1+WORD8+B9600 stop/word/baud (irrelevant - no hw)
         fdb   name
         fcb   C$XON
         fcb   C$XOFF
         fcb   80         columns
         fcb   24         rows
         fcb   $00        extended type
initsize equ   *

name     fcs   /wt/
mgrnam   fcs   /SCF/
drvnam   fcs   /scwpt/

         emod
eom      equ   *
         end
