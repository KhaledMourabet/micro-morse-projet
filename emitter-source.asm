	#include <p18f2520.inc>        ; load the register and bit names of the PIC18F2520
	config osc = intio67           ; use the internal oscillator, with RA6 and RA7 as normal I/O pins
	config wdt = off               ; disable the watchdog timer so it never resets the program

cnt_out equ 0x00                   ; address of the outer loop counter (Access RAM)
cnt_in  equ 0x01                   ; address of the inner loop counter (Access RAM)

	org 0x00                       ; place the code at the reset vector (address 0)

	movlw b'01100000'              ; IRCF2:IRCF0 = 110, which selects 4 MHz for the internal oscillator
	movwf OSCCON                   ; apply the 4 MHz clock setting
	movlw d'25'                    ; SPBRG value for 9600 baud at 4 MHz with BRGH = 1
	movwf SPBRG                    ; load the baud rate generator
	movlw b'00100100'              ; TXEN = 1 (enable transmit), SYNC = 0 (asynchronous), BRGH = 1 (high speed)
	movwf TXSTA                    ; configure the transmitter
	movlw b'10010000'              ; SPEN = 1 (enable serial port), CREN = 1 (enable continuous receive)
	movwf RCSTA                    ; configure the receiver and turn on the serial port
	bcf LATC, 0                    ; set the RC0 output latch to 0 so the LED starts off
	bcf TRISC, 0                   ; make RC0 an output (0 = output)

main_loop                          ; label: start of the dot and dash test
	rcall dot                      ; send one dot (1T high, 1T low)
	rcall dash                     ; send one dash (3T high, 1T low)
	rcall delay_3T                 ; temporary pause so each dot-dash pair is easy to see on the oscilloscope
	bra main_loop                  ; repeat forever

dot                                ; label: dot routine
	bsf LATC, 0                    ; set RC0 high, signal and LED on
	rcall delay_1T                 ; keep it high for 1T (100 ms)
	bcf LATC, 0                    ; set RC0 low, signal and LED off
	rcall delay_1T                 ; keep it low for 1T, the gap after an element
	return                         ; go back to the caller

dash                               ; label: dash routine
	bsf LATC, 0                    ; set RC0 high, signal and LED on
	rcall delay_3T                 ; keep it high for 3T (300 ms)
	bcf LATC, 0                    ; set RC0 low, signal and LED off
	rcall delay_1T                 ; keep it low for 1T, the gap after an element
	return                         ; go back to the caller

delay_1T                           ; label: 1T delay routine, 100 ms at 4 MHz
	movlw d'100'                   ; load 100 into W (100 passes of 1 ms each)
	movwf cnt_out                  ; store it in the outer counter
outer_loop                         ; label: start of one 1 ms pass
	movlw d'249'                   ; load 249 into W (number of inner iterations)
	movwf cnt_in                   ; store it in the inner counter
inner_loop                         ; label: start of the inner loop
	nop                            ; do nothing for 1 cycle, so each inner turn takes 4 cycles
	decfsz cnt_in, F               ; decrement the inner counter, skip the next line when it reaches 0
	bra inner_loop                 ; inner counter not 0 yet, repeat
	decfsz cnt_out, F              ; decrement the outer counter, skip the next line when it reaches 0
	bra outer_loop                 ; outer counter not 0 yet, do another pass
	return                         ; delay finished, go back to the caller

delay_3T                           ; label: 3T delay routine (300 ms)
	rcall delay_1T                 ; wait 1T
	rcall delay_1T                 ; wait another 1T
	rcall delay_1T                 ; wait a third 1T
	return                         ; go back to the caller

delay_7T                           ; label: 7T delay routine (700 ms), used later for the gap between words
	rcall delay_3T                 ; wait 3T
	rcall delay_3T                 ; wait another 3T
	rcall delay_1T                 ; wait 1T, for a total of 7T
	return                         ; go back to the caller

	end                            ; end of the source file