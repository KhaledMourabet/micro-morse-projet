	#include <p18f2520.inc>        ; load the register and bit names of the PIC18F2520
	config osc = intio67           ; use the internal oscillator, with RA6 and RA7 as normal I/O pins
	config wdt = off               ; disable the watchdog timer so it never resets the program

cnt_out  equ 0x00                  ; address of the outer loop counter (Access RAM)
cnt_in   equ 0x01                  ; address of the inner loop counter (Access RAM)
code_reg equ 0x02                  ; address of the Morse code byte currently being sent
char_in  equ 0x03                  ; address of the character being converted, then its table index
head     equ 0x04                  ; address of the buffer write index (0 to 15), changed only by the ISR
tail     equ 0x05                  ; address of the buffer read index (0 to 15), changed only by the main loop
buffer   equ 0x20                  ; start address of the 16-byte receive buffer (0x20 to 0x2F)
rx_char  equ 0x06                  ; address of the received character, kept while the ISR works with W

	org 0x00                       ; place the code at the reset vector (address 0)
	goto start                     ; jump over the interrupt vector to the start of the program
	org 0x08                       ; place the next code at the interrupt vector (address 8)

isr                                ; label: interrupt routine, runs whenever a character is received
	movf RCREG, W                  ; read the received character into W (this also clears RCIF)
	movwf rx_char                  ; save it, because W will be reused below
echo_wait                          ; label: wait until the transmitter can accept a character
	btfss PIR1, TXIF               ; skip the next line if TXIF = 1 (TXREG is empty)
	bra echo_wait                  ; transmitter still busy, check again (at most about 1 ms)
	movwf TXREG                    ; send the character back to the terminal (W still holds it)
	incf head, W                   ; W = head + 1, the next write index
	andlw 0x0F                     ; wrap the index back to 0 after 15
	cpfseq tail                    ; skip the next line if the next index equals tail (buffer full)
	bra store                      ; buffer not full, go and store the character
	retfie FAST                    ; buffer full: the character is dropped, return and restore W, STATUS and BSR
store                              ; label: there is room in the buffer
	lfsr 0, buffer                 ; point FSR0 to the start of the buffer
	movf head, W                   ; W = write index
	addwf FSR0L, F                 ; FSR0 now points to the free slot (buffer + head)
	movf rx_char, W                ; get the saved character back into W
	movwf INDF0                    ; store it in the buffer slot that FSR0 points to
	incf head, W                   ; W = head + 1
	andlw 0x0F                     ; wrap the index back to 0 after 15
	movwf head                     ; save the new write index
	retfie FAST                    ; return from the interrupt, restoring W, STATUS and BSR automatically

start                              ; label: start of the main program
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
	clrf head                      ; start with the write index at 0 (RAM is not cleared at power-up)
	clrf tail                      ; start with the read index at 0, so the buffer is empty
	bsf PIE1, RCIE                 ; enable the UART receive interrupt
	movlw b'11000000'              ; GIE = 1 (global interrupts on), PEIE = 1 (peripheral interrupts on)
	movwf INTCON                   ; turn the interrupts on

main_loop                          ; label: start of the loop that takes characters from the buffer
	movf tail, W                   ; W = read index
	cpfseq head                    ; skip the next line if head equals tail (buffer empty)
	bra take                       ; buffer not empty, go and take a character
	bra main_loop                  ; buffer empty, check again
take                               ; label: there is a character waiting in the buffer
	lfsr 1, buffer                 ; point FSR1 to the start of the buffer
	movf tail, W                   ; W = read index
	addwf FSR1L, F                 ; FSR1 now points to the oldest character (buffer + tail)
	movf INDF1, W                  ; W = the oldest character
	movwf char_in                  ; save the character
	incf tail, W                   ; W = tail + 1
	andlw 0x0F                     ; wrap the index back to 0 after 15
	movwf tail                     ; save the new read index, which frees the slot
	movlw ' '                      ; load the ASCII code of a space (0x20)
	cpfseq char_in                 ; skip the next line if the character is a space
	bra not_space                  ; not a space, go and convert it
	rcall word_gap                 ; space: add 4T of low to reach the 7T gap between words
	bra main_loop                  ; go back and look for the next character
not_space                          ; label: the character is not a space
	rcall get_code                 ; convert char_in into its Morse code byte (W = 0 if invalid)
	tstfsz WREG                    ; skip the next line if W = 0 (invalid character)
	bra play                       ; valid character, go and play it
	bra main_loop                  ; invalid character: ignore it and look for the next one
play                               ; label: the character is valid
	rcall send_code                ; play the code as dots and dashes on RC0
	rcall char_gap                 ; add 2T of low, so the total low after the last element is 3T
	bra main_loop                  ; go back and look for the next character

get_code                           ; label: converts char_in into its Morse code byte in W (0 if invalid)
	movlw '/'                      ; load 0x2F, the character just below '0'
	cpfsgt char_in                 ; skip the next line if char_in > '/' (the character is '0' or above)
	retlw 0                        ; below '0': invalid, return 0
	movlw ':'                      ; load 0x3A, the character just above '9'
	cpfslt char_in                 ; skip the next line if char_in < ':' (the character is '9' or below)
	bra check_letter               ; above '9': it may be a letter
	movlw d'22'                    ; '0' is 48, and 48 - 22 = 26, the table index of '0'
	subwf char_in, F               ; char_in = digit index (26 to 35)
	bra read_table                 ; go and read the table
check_letter                       ; label: the character is above '9'
	movlw '@'                      ; load 0x40, the character just below 'A'
	cpfsgt char_in                 ; skip the next line if char_in > '@' (the character is 'A' or above)
	retlw 0                        ; between ':' and '@': invalid, return 0
	movlw '['                      ; load 0x5B, the character just above 'Z'
	cpfslt char_in                 ; skip the next line if char_in < '[' (the character is 'Z' or below)
	retlw 0                        ; above 'Z' (lowercase included): invalid, return 0
	movlw 'A'                      ; load the ASCII code of 'A' (0x41)
	subwf char_in, F               ; char_in = letter index (0 to 25)
read_table                         ; label: char_in now holds the table index
	movlw low morse_table          ; load the low byte of the table address
	movwf TBLPTRL                  ; store it in the table pointer
	movlw high morse_table         ; load the high byte of the table address
	movwf TBLPTRH                  ; store it in the table pointer
	movf char_in, W                ; load the index into W
	addwf TBLPTRL, F               ; point to the table start + index (low byte)
	movlw 0                        ; load 0 into W (movlw does not change C)
	addwfc TBLPTRH, F              ; add the carry from the low byte to the high byte
	tblrd*                         ; read the table byte at that address into TABLAT
	movf TABLAT, W                 ; copy the Morse code byte into W
	return                         ; go back to the caller

send_code                          ; label: plays the Morse code byte in W as dots and dashes
	movwf code_reg                 ; save the code byte
next_elem                          ; label: start of one element (dot or dash)
	bcf STATUS, C                  ; clear the carry so a 0 enters bit 7 during the shift
	rrcf code_reg, F               ; shift right: the old bit 0 (the current element) goes into C
	bc send_dash                   ; if C = 1 the element is a dash
	rcall dot                      ; C = 0: send a dot
	bra elem_done                  ; skip the dash call
send_dash                          ; label: the element is a dash
	rcall dash                     ; send a dash
elem_done                          ; label: element finished
	decf code_reg, W               ; W = code_reg - 1, which is 0 when only the end marker bit is left
	bnz next_elem                  ; not 0: elements remain, send the next one
	return                         ; only the marker is left, the character is finished

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

char_gap                           ; label: gap between characters (2T added to the 1T already done)
	rcall delay_1T                 ; wait 1T
	rcall delay_1T                 ; wait another 1T, so 2T in total
	return                         ; go back to the caller

word_gap                           ; label: gap between words (4T added to the 3T already done)
	rcall delay_3T                 ; wait 3T
	rcall delay_1T                 ; wait 1T more, so 4T in total
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

morse_table                        ; label: Morse codes, A to Z then 0 to 9 (36 bytes)
	db 0x06, 0x11, 0x15, 0x09, 0x02, 0x14, 0x0B, 0x10, 0x04, 0x1E   ; codes for A B C D E F G H I J
	db 0x0D, 0x12, 0x07, 0x05, 0x0F, 0x16, 0x1B, 0x0A, 0x08, 0x03   ; codes for K L M N O P Q R S T
	db 0x0C, 0x18, 0x0E, 0x19, 0x1D, 0x13                           ; codes for U V W X Y Z
	db 0x3F, 0x3E, 0x3C, 0x38, 0x30, 0x20, 0x21, 0x23, 0x27, 0x2F   ; codes for 0 1 2 3 4 5 6 7 8 9

	end