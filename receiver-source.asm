#include <p18f2520.inc>
	config osc = intio67           ; use the internal oscillator, with RA6 and RA7 as normal I/O pins
	config wdt = off               ; disable the watchdog timer so it never resets the program
	config pbaden = off            ; make RB4:RB0 digital at reset, so RB0 can read the signal from PIC 1

gap      equ 0x00                  ; address of the gap state: 0 = nothing reported, 1 = character end reported, 2 = word end reported
code_reg equ 0x01                  ; address of the Morse code being built (starts at 1, the end marker)
index    equ 0x02                  ; address of the table entry counter used by the decoder

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
	movlw d'1'                     ; load 1 into W (the end marker, an empty code)
	movwf code_reg                 ; start with an empty code
	movlw d'2'                     ; load 2 into W (the idle state)
	movwf gap                      ; start in the idle state, so nothing is reported before the first pulse
	movlw low intro                ; load the low byte of the intro text address
	movwf TBLPTRL                  ; store it in the table pointer
	movlw high intro               ; load the high byte of the intro text address
	movwf TBLPTRH                  ; store it in the table pointer
	rcall send_string              ; print the intro text on Terminal 2

low_wait                           ; label: wait in a LOW period for the next pulse, reporting gaps on the way
	btfsc PORTB, 0                 ; skip the next line if RB0 = 0 (the signal is still low)
	bra pulse                      ; RB0 = 1: a new pulse starts
	movlw d'2'                     ; load 2 into W
	cpfseq gap                     ; skip the next line if gap = 2 (the word end was already reported)
	bra check_gap                  ; gap is 0 or 1: look at the timer
	bra low_wait                   ; gap = 2: nothing left to report, keep waiting
check_gap                          ; label: compare the LOW time with the thresholds
	movf TMR0L, W                  ; read the low byte, which also copies the timer's high byte into TMR0H
	movlw 0xC3                     ; load the silence threshold: 0xC300 counts is about 8T (800 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold
	bra silence_event              ; LOW lasted 8T or more: a human pause, not a space
	tstfsz gap                     ; skip the next line if gap = 0 (the character end was not reported yet)
	bra low_wait                   ; gap = 1: already reported, keep waiting
	movlw 0x30                     ; load the character threshold: 0x3000 counts is about 2T (200 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold
	bra char_event                 ; LOW lasted 2T or more: it is the end of a character
	bra low_wait                   ; threshold not reached yet, keep waiting

char_event                         ; label: the character is finished
	rcall decode                   ; look up the built code, W = decoded character
	rcall send_char                ; print it on Terminal 2
	movlw d'1'                     ; load 1 into W
	movwf code_reg                 ; reset the code to the end marker, ready for the next character
	movwf gap                      ; remember that the character end has been reported (W is still 1)
	bra low_wait                   ; go back to waiting

silence_event                      ; label: a human pause (no space): just stop the timer and wait
	movlw d'2'                     ; load 2 into W (the idle state)
	movwf gap                      ; remember that we are idle, nothing to report
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
	movlw 0x60                     ; load the space threshold: 0x6000 counts is about 4T (400 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold
	bra is_space                   ; the pulse was long enough to be the space marker
	movlw 0x30                     ; load the threshold: 0x3000 counts is about 2T (200 ms)
	cpfslt TMR0H                   ; skip the next line if the high byte is below the threshold (a dot)
	bra is_dash                    ; the pulse was long: it is a dash
	bcf STATUS, C                  ; dot: clear the carry, so a 0 will enter the code
	bra add_element                ; go and add the element
is_dash                            ; label: the pulse was a dash
	bsf STATUS, C                  ; dash: set the carry, so a 1 will enter the code
	bra add_element                ; go and add the element
is_space                           ; label: the pulse was the space marker (5T high)
	movlw ' '                      ; load the ASCII code of a space
	rcall send_char                ; print the space on Terminal 2
	movlw d'1'                     ; load 1 into W (the end marker)
	movwf code_reg                 ; reset the code, ready for the next character
	movlw d'2'                     ; load 2 into W (the idle state)
	movwf gap                      ; nothing to report in the next LOW period
	bra low_wait                   ; go back to waiting
add_element                        ; label: add the element to the code
	rlcf code_reg, F               ; shift the code left and put the carry (0 or 1) into bit 0
	clrf gap                       ; a new LOW period starts: nothing reported yet
	clrf TMR0H                     ; clear the high byte of the timer
	clrf TMR0L                     ; clear the low byte of the timer
	bsf T0CON, TMR0ON              ; start Timer0 to measure the LOW period
	bra low_wait                   ; wait for the next pulse

decode                             ; label: converts code_reg into its character in W ('?' if unknown)
	movlw low morse_table          ; load the low byte of the table address
	movwf TBLPTRL                  ; store it in the table pointer
	movlw high morse_table         ; load the high byte of the table address
	movwf TBLPTRH                  ; store it in the table pointer
	clrf index                     ; start at table entry 0
search                             ; label: compare the code with one table entry
	tblrd*+                        ; read the table entry into TABLAT, then move to the next entry
	movf code_reg, W               ; W = the code we built
	cpfseq TABLAT                  ; skip the next line if the table entry equals the code
	bra next_entry                 ; different: try the next entry
	bra found                      ; equal: the entry number in index is the answer
next_entry                         ; label: move on to the next table entry
	incf index, F                  ; count one more entry
	movlw d'36'                    ; load 36 into W (the number of entries in the table)
	cpfseq index                   ; skip the next line if all 36 entries have been tried
	bra search                     ; entries remain, keep searching
	movlw '?'                      ; no entry matched: load a question mark
	return                         ; go back to the caller
found                              ; label: index holds the position of the matching entry
	movlw d'26'                    ; load 26 into W (the first digit entry)
	cpfslt index                   ; skip the next line if index < 26 (a letter)
	bra digit                      ; index is 26 or more: it is a digit
	movlw 'A'                      ; letter: load the ASCII code of 'A'
	addwf index, W                 ; W = 'A' + index
	return                         ; go back to the caller
digit                              ; label: the entry is a digit
	movlw d'22'                    ; load 22 into W ('0' is 48, and 48 - 26 = 22)
	addwf index, W                 ; W = index + 22, the ASCII code of the digit
	return                         ; go back to the caller

send_char                          ; label: sends the character in W through the UART
	btfss PIR1, TXIF               ; skip the next line if TXIF = 1 (TXREG is empty)
	bra send_char                  ; transmitter still busy, check again
	movwf TXREG                    ; load the character into TXREG, which starts sending it
	return                         ; go back to the caller

morse_table                        ; label: codes in arrival order with a leading 1 marker, A to Z then 0 to 9
	db 0x05, 0x18, 0x1A, 0x0C, 0x02, 0x12, 0x0E, 0x10, 0x04, 0x17   ; codes for A B C D E F G H I J
	db 0x0D, 0x14, 0x07, 0x06, 0x0F, 0x16, 0x1D, 0x0A, 0x08, 0x03   ; codes for K L M N O P Q R S T
	db 0x09, 0x11, 0x0B, 0x19, 0x1B, 0x1C                           ; codes for U V W X Y Z
	db 0x3F, 0x2F, 0x27, 0x23, 0x21, 0x20, 0x30, 0x38, 0x3C, 0x3E   ; codes for 0 1 2 3 4 5 6 7 8 9

send_string                        ; label: prints the text at the table pointer, up to the 0 terminator
	tblrd*+                        ; read the next byte into TABLAT, then move the pointer on
	movf TABLAT, W                 ; copy the byte into W (this also sets the zero flag if the byte is 0)
	bz string_end                  ; the byte is 0: the text is finished
	rcall send_char                ; send the character through the UART
	bra send_string                ; go and read the next byte
string_end                         ; label: end of the text
	return                         ; go back to the caller

intro                              ; label: the start-up text, ending with a new line and a 0 terminator
	db "You received:", 0x0D, 0x0A, 0x00   ; text, carriage return, line feed, end marker
	end