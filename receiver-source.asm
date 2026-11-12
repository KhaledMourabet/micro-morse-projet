	#include <p18f2520.inc>        ; load the register and bit names of the PIC18F2520
	config osc = intio67           ; use the internal oscillator, with RA6 and RA7 as normal I/O pins
	config wdt = off               ; disable the watchdog timer so it never resets the program
	config pbaden = off            ; make RB4:RB0 digital at reset, so RB0 can read the signal from PIC 1

gap equ 0x00                       ; address of the gap state: 0 = nothing reported, 1 = character end reported, 2 = word end reported

	org 0x00                       ; place the code at the reset vector (address 0)

	movlw b'01100000'              ; IRCF2:IRCF0 = 110, which selects 4 MHz for the internal oscillator
	movwf OSCCON                   ; apply the 4 MHz clock setting
	movlw d'25'                    ; SPBRG value for 9600 baud at 4 MHz with BRGH = 1
	movwf SPBRG                    ; load the baud rate generator
	movlw b'00100100'              ; TXEN = 1 (enable transmit), SYNC = 0 (asynchronous), BRGH = 1 (high speed)
	movwf TXSTA                    ; configure the transmitter
	movlw b'10000000'              ; SPEN = 1 (enable serial port), CREN = 0 because this PIC only transmits
	movwf RCSTA                    ; turn on the serial port
	movlw b'00000011'              ; TMR0ON = 0 (off), T08BIT = 0 (16-bit), T0CS = 0 (internal clock), PSA = 0, T0PS = 011 (1:16)
	movwf T0CON                    ; configure Timer0: one count every 16 us
	movlw d'2'                     ; load 2 into W (the idle state)
	movwf gap                      ; start in the idle state, so nothing is reported before the first pulse

low_wait                           ; label: wait in a LOW period for the next pulse, reporting gaps on the way
	btfsc PORTB, 0                 ; skip the next line if RB0 = 0 (the signal is still low)
	bra pulse                      ; RB0 = 1: a new pulse starts
	movlw d'2'                     ; load 2 into W
	cpfseq gap                     ; skip the next line if gap = 2 (the word end was already reported)
	bra check_gap                  ; gap is 0 or 1: look at the timer
	bra low_wait                   ; gap = 2: nothing left to report, keep waiting
check_gap                          ; label: compare the LOW time with the thresholds
	movf TMR0L, W                  ; read the low byte, which also copies the timer's high byte into TMR0H
	movlw 0x7A                     ; load the word threshold: 0x7A00 counts is about 5T (500 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold
	bra word_event                 ; LOW lasted 5T or more: it is the end of a word
	tstfsz gap                     ; skip the next line if gap = 0 (the character end was not reported yet)
	bra low_wait                   ; gap = 1: already reported, keep waiting
	movlw 0x30                     ; load the character threshold: 0x3000 counts is about 2T (200 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold
	bra char_event                 ; LOW lasted 2T or more: it is the end of a character
	bra low_wait                   ; threshold not reached yet, keep waiting

char_event                         ; label: the character is finished
	movlw ' '                      ; load the ASCII code of a space
	rcall send_char                ; print it on Terminal 2
	movlw d'1'                     ; load 1 into W
	movwf gap                      ; remember that the character end has been reported
	bra low_wait                   ; go back to waiting

word_event                         ; label: the word is finished
	movlw '/'                      ; load the ASCII code of a slash
	rcall send_char                ; print it on Terminal 2
	movlw d'2'                     ; load 2 into W
	movwf gap                      ; remember that the word end has been reported (idle state)
	bcf T0CON, TMR0ON              ; stop Timer0, so it cannot overflow during a long silence
	bra low_wait                   ; go back to waiting

pulse                              ; label: a HIGH pulse has started, measure it
	clrf TMR0H                     ; clear the high byte (written to the buffer first)
	clrf TMR0L                     ; clear the low byte (this also loads the high byte into the timer)
	bsf T0CON, TMR0ON              ; start Timer0 at the beginning of the pulse
wait_low                           ; label: wait for the end of the HIGH pulse
	btfsc PORTB, 0                 ; skip the next line if RB0 = 0 (the signal went low)
	bra wait_low                   ; signal still high, check again
	bcf T0CON, TMR0ON              ; stop Timer0 at the end of the pulse
	movf TMR0L, W                  ; read the low byte, which also copies the timer's high byte into TMR0H
	movlw 0x30                     ; load the threshold: 0x3000 counts is about 2T (200 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold (a dot)
	bra is_dash                    ; the pulse was long: it is a dash
	movlw '.'                      ; short pulse: load the ASCII code of a dot
	bra send                       ; go and send it
is_dash                            ; label: the pulse was a dash
	movlw '-'                      ; load the ASCII code of a dash
send                               ; label: send the character in W to Terminal 2
	rcall send_char                ; transmit W through the UART
	clrf gap                       ; a new LOW period starts: nothing reported yet
	clrf TMR0H                     ; clear the high byte of the timer
	clrf TMR0L                     ; clear the low byte of the timer
	bsf T0CON, TMR0ON              ; start Timer0 to measure the LOW period
	bra low_wait                   ; wait for the next pulse

send_char                          ; label: sends the character in W through the UART
	btfss PIR1, TXIF               ; skip the next line if TXIF = 1 (TXREG is empty)
	bra send_char                  ; transmitter still busy, check again
	movwf TXREG                    ; load the character into TXREG, which starts sending it
	return                         ; go back to the caller

	end                            ; end of the source file