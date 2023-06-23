.include "x16.inc"
.include "audio.inc"
.include "macros.inc"

.macpack longbranch

.export init_engine
.export zsm_tick
.export zsm_play
.export zsm_stop
.export zsm_close
.ifdef ZSMKIT_ENABLE_STREAMING
.export zsm_fill_buffers
.export zsm_setlfs
.export zsm_setfile
.endif
.export zsm_setmem
.export zsm_setatten
.export zsm_rewind


NUM_PRIORITIES = 4
FILENAME_MAX_LENGTH = 64
RINGBUFFER_SIZE = 1024

.segment "ZSMKITLIB"
zsmkit_bank: ; the RAM bank dedicated to ZSMKit to use for state
	.res 1
saved_bank: ; used for preserving the bank in main loop calls
	.res 1
saved_bank_irq: ; used for preserving the bank in IRQ call
	.res 1
buff: ; used for things like filenames which need to be in low RAM
	.res FILENAME_MAX_LENGTH
tmp1 := buff
tmp2 := buff+3
tmp3 := buff+6

.segment "ZSMKITBANK"
_ZSM_BANK_START := *

; To support the option of streaming ZSM data from SD card,
; ZSMKit allocates 1k for each of the four priorities.
; These ring buffers are fed by calling `zsm_fill_buffers`
; in the program's main loop. In the event of an underrun,
; the engine will halt the song and mark it as not playable.
;
; The ring buffers for the four priorities are located at:
; 0:$A000 1:$A400 2:$A800 3:$AC00
;
; offset = (priority * 1024)
zsm_ringbuffers:        .res NUM_PRIORITIES*RINGBUFFER_SIZE

; offset = priority*256
opm_shadow:             .res NUM_PRIORITIES*256

; offset = (priority * 64) + (register)
vera_psg_shadow:        .res NUM_PRIORITIES*64

; offset = (priority * 8) + (voice)
opm_atten_shadow:       .res NUM_PRIORITIES*8

; offset = (priority * 16) + (voice)
vera_psg_atten_shadow:  .res NUM_PRIORITIES*16

; These two arrays are set via properties on the ZSM
; based on which voices are used.  If the priority slot
; is not active, these are zeroed.

; offset = (priority * 8) + (voice)
opm_voice_mask:         .res NUM_PRIORITIES*8

; offset = (priority * 16) + (voice)
vera_psg_voice_mask:    .res NUM_PRIORITIES*16

; Is the song playing? Nonzero is truth.
; offset = (priority)
prio_active:            .res NUM_PRIORITIES

; Did the player encounter a fault of some sort?
; This is set zero whenever that happens
; It is set nonzero when a file is loaded and
; is ready
prio_playable:          .res NUM_PRIORITIES

.ifdef ZSMKIT_ENABLE_STREAMING
; Is the song fully in memory or played through a 1k ring buffer?
; zero = traditional memory storage, nonzero = ring buffer
; offset = (priority)
streaming_mode:         .res NUM_PRIORITIES

; The ring buffer positions (absolute addresses)
; offset = (priority)
ringbuffer_start_l:     .res NUM_PRIORITIES
ringbuffer_start_h:     .res NUM_PRIORITIES

; offset = (priority)
; end is non-inclusive
ringbuffer_end_l:       .res NUM_PRIORITIES
ringbuffer_end_h:       .res NUM_PRIORITIES

; 24 bit address within the file
; where the loop point exists
; offset = (priority)
streaming_loop_point_l: .res NUM_PRIORITIES
streaming_loop_point_m: .res NUM_PRIORITIES
streaming_loop_point_h: .res NUM_PRIORITIES

; When `zsm_fill_buffers` encounters EOI, this flag is set.
; Since opening a file can be expensive, we save that for
; the next tick. That call then reopens the file, seeks
; to the loop point, and then returns. The call on the tick
; subsequent to that is the first to start pumping data
; into the ring buffer again.
streaming_reopen:       .res NUM_PRIORITIES

; streaming filename OPEN string, must be <=64 bytes
; we need to keep this in the engine because looping
; will typically require the file to be reopened.
; offset = (priority*64)
streaming_filename:     .res NUM_PRIORITIES*FILENAME_MAX_LENGTH
; offset = (priority)
streaming_filename_len: .res NUM_PRIORITIES

; The logical file number and the secondary address are both the same
; and are assigned by the user
streaming_lfn_sa:       .res NUM_PRIORITIES

; Device, almost always 8
streaming_dev:          .res NUM_PRIORITIES

; Goes true when streaming is finished
streaming_finished:     .res NUM_PRIORITIES
.endif

; For non-streaming mode, the bank and offset of the beginning of
; the song, loop point, and of the current pointer
; offset = (priority)
zsm_start_bank:         .res NUM_PRIORITIES
zsm_start_l:            .res NUM_PRIORITIES
zsm_start_h:            .res NUM_PRIORITIES

zsm_loop_bank:          .res NUM_PRIORITIES
zsm_loop_l:             .res NUM_PRIORITIES
zsm_loop_h:             .res NUM_PRIORITIES 

zsm_ptr_bank:           .res NUM_PRIORITIES
zsm_ptr_l:              .res NUM_PRIORITIES
zsm_ptr_h:              .res NUM_PRIORITIES

; For both streaming and non-streaming mode
loop_enable:            .res NUM_PRIORITIES

; Hz (from file)
tick_rate_l:            .res NUM_PRIORITIES
tick_rate_h:            .res NUM_PRIORITIES

; speed (Hz/60) - delays to subtract per tick
speed_f:                .res NUM_PRIORITIES
speed_l:                .res NUM_PRIORITIES
speed_h:                .res NUM_PRIORITIES

; delay (playback state)
delay_f:                .res NUM_PRIORITIES
delay_l:                .res NUM_PRIORITIES
delay_h:                .res NUM_PRIORITIES


; These arrays contain $FF if the voice is unused or will contain
; the priority (0-3) of the module that is allowed to use the voice.
; Other active modules will only feed their shadow instead.
;
; Forced inhibit of a voice will set this priority to $FE.
; This is useful when manipulating a voice directly in user code.
;
; Generally the value is set to the highest module
; priority (slot) which uses the voice
opm_priority:            .res 8
vera_psg_priority:       .res 16

; restore shadow at beginning of next tick
; for opm, this means releasing the note on this channel
; after setting the fastest release time possible
; before copying the shadow in
opm_restore_shadow:      .res 8
vera_psg_restore_shadow: .res 16

; the flag to indicate that we need to re-evaluate the priorities
; since it's likely a song is no longer playing
recheck_priorities:      .res 1

_ZSM_BANK_END := *


.segment "ZSMKITLIB"
;..............
; init_engine :
;============================================================================
; Arguments: .A = designated RAM bank to use for ZSMKit engine state
; Returns: (none)
; Preserves: .P
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Initializes the memory locations used by ZSMKit's engine and calls
; audio_init using the X16's AUDIO API to reset its state..
; Needs to be called once before any other ZSMKit function.

.proc init_engine: near
	php
	sei

	sta zsmkit_bank
	JSRFAR audio_init, $0A
	PRESERVE_BANK_CLOBBER_A_P

	; This will overshoot the allocated part of the ZSM
	; bank and round up to the page boundary, which
	; should be fine

	ldx #<_ZSM_BANK_START
	stz P1
	lda #>_ZSM_BANK_START
	sta P1+1
eraseloop:
	stz $a000,x
P1=*-2
	inx
	bne eraseloop
	cmp #>_ZSM_BANK_END
	bcs erasedone
	lda P1+1
	inc
	sta P1+1
	bra eraseloop
erasedone:

.ifdef ZSMKIT_ENABLE_STREAMING
	ldx #NUM_PRIORITIES-1
prioloop:
	lda #8
	sta streaming_dev,x
	txa
	clc
	adc #11
	sta streaming_lfn_sa,x

	dex
	bpl prioloop
.endif

	RESTORE_BANK
	plp
	rts
.endproc

;...........
; zsm_tick :
;============================================================================
; Arguments: (none)
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: yes
; ---------------------------------------------------------------------------
;
; Master player tick entry point
;
; advances songs and plays the notes
;
.proc zsm_tick: near
	PRESERVE_BANK_CLOBBER_A_P_IRQ

	lda X16::Reg::ROMBank
	sta R1
	lda #$0A
	sta X16::Reg::ROMBank

	; preserve VERA state
	lda Vera::Reg::Ctrl
	sta C1
	stz Vera::Reg::Ctrl
	lda Vera::Reg::AddrL
	sta A1
	lda Vera::Reg::AddrM
	sta A2
	lda Vera::Reg::AddrH
	sta A3

	; point to PSG page, no increment
	lda #$01
	sta Vera::Reg::AddrH
	lda #$f9
	sta Vera::Reg::AddrM

	jsr _reprio
	jsr _reshadow
	ldx #NUM_PRIORITIES-1
	stx prio
prioloop:
	jsr _prio_tick
	ldx prio
	dex
	stx prio
	bpl prioloop

	; restore VERA state
	lda #$ff
A3 = *-1
	sta Vera::Reg::AddrH
	lda #$ff
A2 = *-1
	sta Vera::Reg::AddrM
	lda #$ff
A1 = *-1
	sta Vera::Reg::AddrL
	lda #$ff
C1 = *-1
	sta Vera::Reg::Ctrl	
	lda #$ff
R1 = *-1
	sta X16::Reg::ROMBank
	RESTORE_BANK_IRQ
	rts
prio:
	.byte 0
.endproc

;.............
; _prio_tick :
;============================================================================
; Arguments: X = priority
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: yes
; ---------------------------------------------------------------------------
; 
; The meat of the engine, ticks the priority forward if it is eligible to run
;
.proc _prio_tick: near
	lda prio_active,x
	beq exit

	; subtract the delay, if we go negative we loop until we accumulate enough
	; delay to go positive
	lda delay_f,x
	sec
	sbc speed_f,x
	sta delay_f,x
	lda delay_l,x
	sbc speed_l,x
	sta delay_l,x
	lda delay_h,x
	sbc speed_h,x
	sta delay_h,x
	bpl exit ; no events this tick

	; set up the shadow writes
	lda times_64,x
	adc #<vera_psg_shadow
	sta PS
	lda #>vera_psg_shadow
	adc #0
	sta PS+1

	txa
	clc
	adc #>opm_shadow
	sta OS

.ifdef ZSMKIT_ENABLE_STREAMING
	lda streaming_mode,x
	beq memory
	lda ringbuffer_start_l,x
	sta PTR
	lda ringbuffer_start_h,x
	sta PTR+1
	bra note_loop
.endif
memory:
	lda zsm_ptr_l,x
	sta PTR
	lda zsm_ptr_h,x
	sta PTR+1
	
note_loop:
	jsr getzsmbyte
	bpl isdata
	cmp #$80 ; eod?
	beq iseod
	; is delay
	and #$7f
	cmp #$30
	clc
	adc delay_l,x
	sta delay_l,x
	bcc nextnote
	inc delay_h,x
nextnote:
	jsr advanceptr	
	bcs error
	lda delay_h,x
	bmi note_loop
exit:
	rts
plaxerror:
	pla
plxerror:
	plx
error:
	lda #$80
	sta recheck_priorities
	stz prio_playable,x
	stz prio_active,x
	rts
isdata:
	cmp #$40
	beq isext
	bcs isopm
	; is psg
	stx prio
	pha
	jsr advanceptr
	bcs plaxerror
	jsr getzsmbyte
	plx
	sta vera_psg_shadow,x ; operand is overwritten at sub entry
PS = *-2
	jsr _psg_write
	ldx prio
	bra nextnote
iseod:
	lda loop_enable,x
	bne islooped
	stz prio_active,x
	lda #$80
	sta recheck_priorities
	rts
isext:
	jsr advanceptr
	bcs error
	jsr getzsmbyte
	and #$3f
	; eat the data bytes, up to 63 of them
	tay
	beq nextnote
:	jsr advanceptr
	bcs error
	dey
	bne :-
	bra nextnote
isopm:
	and #$3f
	tay
opmloop:
	jsr advanceptr
	bcs error
	jsr getzsmbyte
	stx prio
	pha
	jsr advanceptr
	bcs plaxerror
	jsr getzsmbyte
	plx
	sta opm_shadow,x ; operand is overwritten at sub entry
OS = *-1
	phy
	jsr _ym_write
	ply
	ldx prio
	dey
	bne opmloop
	jmp nextnote
islooped:
.ifdef ZSMKIT_ENABLE_STREAMING
	; if we're in streaming mode, we basically ignore the eod
	; and assume there's valid ZSM data that's been fetched
	; for us immediately afterwards
	lda streaming_mode,x
	jne nextnote
.endif
	; if it's memory, we just repoint the pointer
	lda zsm_loop_bank,x
	sta zsm_ptr_bank,x
	lda zsm_loop_l,x
	sta zsm_ptr_l,x
	sta PTR
	lda zsm_loop_h,x
	sta zsm_ptr_h,x
	sta PTR+1
	jmp note_loop

getzsmbyte:
	lda zsm_ptr_bank,x
	sta X16::Reg::RAMBank
	lda $ffff
PTR = *-2
	pha
	lda zsmkit_bank
	sta X16::Reg::RAMBank
	pla
	rts
advanceptr:
	inc PTR
	bne :+
	inc PTR+1
:	lda PTR+1
.ifdef ZSMKIT_ENABLE_STREAMING
	bit streaming_mode,x
	bpl @mem
	sta ringbuffer_start_h,x
	cmp ringbuffer_end_page,x
	bcc :+
	lda ringbuffer_start_page,x
	sta PTR+1
	sta ringbuffer_start_h,x
:   cmp ringbuffer_end_h,x
	bne :+
	lda PTR
	sta ringbuffer_start_l,x
	cmp ringbuffer_end_l,x
	rts
:	lda PTR
	sta ringbuffer_start_l,x
	clc
	rts
.endif
@mem:
	cmp #$c0
	bcc :+
	inc zsm_ptr_bank,x
	lda #$a0
	sta PTR+1
	clc
:	sta zsm_ptr_h,x
	lda PTR
	sta zsm_ptr_l,x
	rts

_psg_write:
	pha ; preserve value
	txa ; register
	lsr
	lsr ; now it's voice
	tay
	lda vera_psg_priority,y
	cmp prio
	bne :+
	pla ; restore value
	jmp psg_write_fast
:	pla ; restore value
	rts

_ym_write:
	pha ; preserve value
	cpx #$08
	beq @key ; register 8 is key-off/key-on, and value => voice
	cpx #$20
	bcc @zero ; other registers < $20 are owned by prio 0
	txa ; >= $20 the voice is the low 3 bits of the register
@key:
	and #$07
	tay
	lda opm_priority,y
@cz:
	cmp prio
	bne @skip
	pla
	jmp ym_write
@zero:
	lda #0
	bra @cz
@skip:
	pla ; restore value
	rts

prio:
	.byte 0
.endproc

;............
; _reprio   :
;============================================================================
; Arguments: (none)
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: yes
; ---------------------------------------------------------------------------
; 
; processes any voice switch events that are needed chiefly due to songs no
; longer running, setting up for the reshadow
;
.proc _reprio: near
	lda recheck_priorities
	beq exit

	ldx #0
opmloop:
	ldy opm_priority,x
	cpy #NUM_PRIORITIES ; $fe or $ff, most likely
	bcs opmnext
	lda prio_playable,y
	beq opmswitch
	lda prio_active,y
	beq opmswitch
	lda times_8,y
	adc #<opm_voice_mask
	sta OVM
	lda #>opm_voice_mask
	adc #0
	sta OVM+1
	lda opm_voice_mask,x
OVM = * -2
	bne opmnext
opmswitch:
	lda #$80
	sta opm_restore_shadow,x
	dec opm_priority,x ; see if the next lower priority is active
	bra opmloop
opmnext:
	inx
	cpx #8
	bne opmloop

	ldx #0
psgloop:
	ldy vera_psg_priority,x
	cpy #NUM_PRIORITIES ; $fe or $ff, most likely
	bcs psgnext
	lda prio_playable,y
	beq psgswitch
	lda prio_active,y
	beq psgswitch
	lda times_16,y
	adc #<vera_psg_voice_mask
	sta PVM
	lda #>vera_psg_voice_mask
	adc #0
	sta PVM+1
	lda vera_psg_voice_mask,x
PVM = * -2
	bne psgnext
psgswitch:
	lda #$80
	sta vera_psg_restore_shadow,x
	dec vera_psg_priority,x ; see if the next lower priority is active
	bra psgloop
psgnext:
	inx
	cpx #16
	bne psgloop

	stz recheck_priorities
exit:
	rts
.endproc

;............
; _reshadow :
;============================================================================
; Arguments: (none)
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: yes
; ---------------------------------------------------------------------------
; 
; processes any voice switch events that require reading from the shadow
; and applying the saved state to the sound chips
;
.proc _reshadow: near
	ldx #0
	stx voice

opmloop:
	lda opm_restore_shadow,x
	beq opmnext

	lda opm_priority,x
	cmp #NUM_PRIORITIES
	bcs opmnext ; this happens immediately after a voice stops but no other song is taking over

	; set release phase to $ff for this voice
	lda #$ff
	ldy voice
	ldx rr_m1,y
	jsr ym_write

	ldy voice
	ldx rr_m2,y
	jsr ym_write

	ldy voice
	ldx rr_c1,y
	jsr ym_write

	ldy voice
	ldx rr_c2,y
	jsr ym_write

	; release voice
	lda voice
	jsr ym_release

	; reshadow all parameters
	ldy voice
	ldx opm_priority,y

	lda times_8,x
	adc #<opm_atten_shadow
	sta OASR
	lda #>opm_atten_shadow
	adc #0
	sta OASR+1

	lda opm_priority,y	

	clc
	adc #>opm_shadow
	sta OH

	lda #$20
	clc
	adc voice
	tax
shopmloop:
	lda opm_shadow,x
OH = *-1
	jsr ym_write
	txa
	clc
	adc #$08
	tax
	bcc shopmloop

	ldy voice
	ldx opm_atten_shadow,y
OASR = *-2
	tya
	jsr ym_setatten
opmnext:
	ldx voice
	stz opm_restore_shadow,x
	inx
	stx voice
	cpx #8
	jcc opmloop


	ldx #0
	stx voice
psgloop:
	lda vera_psg_restore_shadow,x
	beq psgnext

	lda vera_psg_priority,x
	cmp #NUM_PRIORITIES
	bcs psgnext ; this happens immediately after a voice stops but no other song is taking over

	tax
	lda times_64,x
	adc #<vera_psg_shadow
	sta PL
	lda #>vera_psg_shadow
	adc #0
	sta PL+1

	ldy voice
	ldx vera_psg_priority,y

	lda times_16,x
	clc
	adc #<vera_psg_atten_shadow
	sta PASR
	lda #>vera_psg_atten_shadow
	adc #0
	sta PASR+1

	lda voice
	asl
	asl
	tax
	ldy #4
shpsgloop:
	phy
	lda vera_psg_shadow,x
PL = *-2
	jsr psg_write_fast
	ply
	inx
	dey
	bne shpsgloop

	ldy voice
	ldx vera_psg_atten_shadow,y
PASR = *-2
	tya
	jsr psg_setatten

psgnext:
	ldx voice
	stz vera_psg_restore_shadow,x
	inx
	stx voice
	cpx #16
	bcc psgloop

	rts
voice:
	.byte 0
.endproc

;...............
; zsm_setatten :
;============================================================================
; Arguments: .X = priority, A. = value
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Sets the attenuation value of a song.  $00 = full volume, $3F-7F = muted
; At $3F, the OPM is very close to muted and the PSG is definitely muted
; At $7F, both will be muted
.proc zsm_setatten: near
	; psg steps are 0.5dB
	; opm steps are 0.75dB
	sta val
	lsr
	sta valopm
	lda val
	sec
	sbc valopm
	sta valopm
	stx prio

	PRESERVE_BANK_CLOBBER_A_P
	lda X16::Reg::ROMBank
	pha
	lda #$0a
	sta X16::Reg::ROMBank

	lda times_16,x
	clc
	adc #<vera_psg_atten_shadow
	sta PAS
	lda #>vera_psg_atten_shadow
	adc #0
	sta PAS+1

	lda times_8,x
	adc #<opm_atten_shadow
	sta OAS
	lda #>opm_atten_shadow
	adc #0
	sta OAS+1

	php ; protect critical section
	sei

	ldy #0
psgloop:
	lda vera_psg_priority,y
	cmp prio
	bne :+
	ldx val
	tya
	phy
	jsr psg_setatten
	ply 
:	lda val
	sta vera_psg_atten_shadow,y
PAS = *-2
	iny
	cpy #16
	bne psgloop

	ldy #0
opmloop:
	lda opm_priority,y
	cmp prio
	bne :+
	ldx valopm
	tya
	phy
	jsr ym_setatten
	ply 
:	lda valopm
	sta opm_atten_shadow,y
OAS = * -2
	iny
	cpy #8
	bne opmloop

	plp

exit:
	pla
	sta X16::Reg::ROMBank
	RESTORE_BANK
	rts
prio:
	.byte 0
val:
	.byte 0
valopm:
	.byte 0
.endproc

;.............
; zsm_rewind :
;============================================================================
; Arguments: .X = priority
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; stops playback if necessary and resets the song pointer to the beginning
;
.proc zsm_rewind: near
	stx prio
	PRESERVE_BANK_CLOBBER_A_P
	lda prio_active,x
	beq :+
	RESTORE_BANK
	jsr zsm_stop
	PRESERVE_BANK_CLOBBER_A_P
	ldx prio
:
.ifdef ZSMKIT_ENABLE_STREAMING
	lda streaming_mode,x
	beq memory
	stz prio_playable,x
	stz streaming_finished,x
	jsr _open_and_parse

	ldx prio
	bra cont
.endif
memory:	
	lda zsm_start_l,x
	sta zsm_ptr_l,x
	lda zsm_start_h,x
	sta zsm_ptr_h,x
	lda zsm_start_bank,x
	sta zsm_ptr_bank,x
	
cont:
	RESTORE_BANK
	rts
prio:
	.byte 0
.endproc


;............
; zsm_close :
;============================================================================
; Arguments: .X = priority
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; closes streaming songs, sets priority to unused/not playable
;
.proc zsm_close: near
	stx prio
	PRESERVE_BANK_CLOBBER_A_P
	lda prio_active,x
	beq :+
	RESTORE_BANK
	jsr zsm_stop
	PRESERVE_BANK_CLOBBER_A_P
	ldx prio
:
.ifdef ZSMKIT_ENABLE_STREAMING
	lda streaming_mode,x
	beq :+
	lda streaming_lfn_sa,x
	jsr X16::Kernal::CLOSE
	ldx prio
	stz streaming_finished,x
:	
.endif
	stz prio_playable,x

	RESTORE_BANK
	rts
prio:
	.byte 0
.endproc

;...........
; zsm_stop :
;============================================================================
; Arguments: .X = priority
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Stops or pauses a song priority.  For in-memory songs, nothing else is needed
; for cleanup.  For streaming priorities, the file is held open until `zsm_close`
; is called
.proc zsm_stop: near
	PRESERVE_BANK_CLOBBER_A_P
	lda X16::Reg::ROMBank
	pha
	lda #$0a
	sta X16::Reg::ROMBank
	php ; mask interrupts while we clean up
	sei

	lda prio_active,x
	beq exit

	stx prio

	ldy #0
psgloop:
	lda vera_psg_priority,y
	cmp prio
	bne psgnext
	phy
	tya
	ldx #0
	jsr psg_setvol
	ply
psgnext:
	iny
	cpy #16
	bne psgloop

	ldy #0
opmloop:
	lda opm_priority,y
	cmp prio
	bne opmnext
	phy
	tya
	ldx #8
	jsr ym_write
	; perhaps we should set fast release here too
	ply
opmnext:
	iny
	cpy #8
	bne opmloop

	ldx prio
	stz prio_active,x
	lda #$80
	sta recheck_priorities

exit:
	plp ; restore interrupt mask state
	pla
	sta X16::Reg::ROMBank
	RESTORE_BANK
	rts
prio:
	.byte 0
.endproc

;...........
; zsm_play :
;============================================================================
; Arguments: .X = priority
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Sets up the song to start playing back on the next tick if
; the song is valid and ready to play
.proc zsm_play: near
	PRESERVE_BANK_CLOBBER_A_P
	lda prio_active,x
	bne exit ; already playing

	lda prio_playable,x
	beq exit

.ifdef ZSMKIT_ENABLE_STREAMING
	lda streaming_finished,x
	bne exit

	lda streaming_mode,x
	bne ok
.endif

	lda zsm_ptr_bank,x
	bne ok
	lda zsm_ptr_h,x
	cmp #$A0
	bcc exit
ok:
	stx prio
	; prevent interrupt during critical section
	php
	sei

	; check to see if we restore shadow from somewhere active next tick
	; opm voices
	ldy times_8,x
	ldx #0
opmloop:
	lda opm_voice_mask,y
	beq nextopm
	lda opm_priority,x
	cmp #$ff
	beq opmvoice
	cmp prio
	bcs nextopm
opmvoice:
	lda #$80
	sta opm_restore_shadow,x
	lda prio
	sta opm_priority,x
nextopm:
	iny
	inx
	cpx #8
	bcc opmloop

	; psg voices
	ldx prio
	ldy times_16,x
	ldx #0
psgloop:
	lda vera_psg_voice_mask,y
	beq nextpsg
	lda vera_psg_priority,x
	cmp #$ff
	beq psgvoice
	cmp prio
	bcs nextpsg
psgvoice:
	lda #$80
	sta vera_psg_restore_shadow,x
	lda prio
	sta vera_psg_priority,x
nextpsg:
	iny
	inx
	cpx #16
	bcc psgloop

	; indicate prio is now active
	ldx prio
	lda #$80
	sta prio_active,x

.ifdef ZSMKIT_ENABLE_STREAMING
	jsr zsm_fill_buffers
.endif

	plp ; end critical section
exit:
	RESTORE_BANK
	rts
prio:
	.byte 0
.endproc

.ifdef ZSMKIT_ENABLE_STREAMING
;...................
; zsm_fill_buffers :
;============================================================================
; Arguments: (none)
; Returns: (none)
; Preserves: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; If the priority has a song being streamed from a file, top the ring buffer
; off if appropriate. Must be called from the main loop since it deals with
; file I/O

.proc zsm_fill_buffers: near
	PRESERVE_BANK_CLOBBER_A_P
	ldx #(NUM_PRIORITIES-1)
loop:
	stx prio
	lda prio_active,x
	jeq next
	lda streaming_mode,x
	jeq next
	lda streaming_finished,x
	jne next
	lda streaming_reopen,x
	beq no_reopen

	jsr _open_zsm ; does not clobber x

	stz streaming_reopen,x
	jmp next
no_reopen:
	; find the amount of free ring buffer space
	lda ringbuffer_end_h,x
	cmp ringbuffer_start_h,x
	bcc mode2
mode1:
	; end is greater than or equal to start
	; (right boundary of load is high ring boundary)
	lda ringbuffer_start_h,x
	clc
	adc #(ringbuffer_end_page-ringbuffer_start_page)
	sta stop_before
	lda ringbuffer_end_page,x ; non-inclusive
	clc ; we're going to subtract one extra intentionally
	sbc ringbuffer_end_h,x
	beq shortpage
	lda #255 ; max less than one page
	bra loadit
mode2:
	; start is greater than end
	; (right boundary of load is end of page one page before start)
	lda ringbuffer_start_h,x
	sta stop_before
	clc ; we're going to subtract one extra intentionally
	sbc ringbuffer_end_h,x
	beq shortpage
	lda #255 ; max less than one page
	bra loadit
shortpage:
	; but first test if we need to skip the load entirely
	lda stop_before
	clc
	sbc ringbuffer_end_h,x
	bne :+
	lda ringbuffer_end_l,x
	bne next ; skip the load, not enough ring buffer
	lda #$ff
	bra loadit
:	; read to the end of the page
	lda #$ff
	eor ringbuffer_end_l,x
	inc
	bne loadit
	dec ; except when we'd ask for 256 bytes.  Ask for 255 instead
loadit:
	pha ; save requested byte count
	lda streaming_lfn_sa,x
	tax
	jsr X16::Kernal::CHKIN
	ldx prio
	ldy ringbuffer_end_h,x
	lda ringbuffer_end_l,x
	tax
	pla ; restore requested byte count
	clc
	jsr X16::Kernal::MACPTR
	bcs error
	txa
	ldx prio
	php ; mask interrupts while changing the lo/hi of end
	sei
	adc ringbuffer_end_l,x
	sta ringbuffer_end_l,x
	lda ringbuffer_end_h,x
	adc #0
	cmp ringbuffer_end_page,x ; non-inclusive
	bcc :+
	lda ringbuffer_start_page,x ; we wrap now
:	sta ringbuffer_end_h,x
	plp ; restore interrupt mask state
	; now check for EOI
	jsr X16::Kernal::READST
	and #$40
	beq check_enough
	; we reached EOI, re-seek next call if we loop
	lda loop_enable,x
	beq finish
	lda #$80
	sta streaming_reopen,x
check_enough:
	jsr X16::Kernal::CLRCHN
	ldx prio
	lda ringbuffer_start_h,x
	cmp ringbuffer_end_h,x
	jeq loop ; get more if start and end are on the same page
next:
	dex
	bmi :+
	jmp loop
:
	RESTORE_BANK
	rts
error:
	ldx prio
	stz prio_playable,x
	lda #$80
	sta recheck_priorities
finish:
	jsr X16::Kernal::CLRCHN
	ldx prio
	lda streaming_lfn_sa,x
	jsr X16::Kernal::CLOSE
	ldx prio
	lda #$80
	sta streaming_finished,x

	bra next
prio:
	.byte 0
stop_before:
	.byte 0
.endproc

;.............
; zsm_setlfs :
;============================================================================
; Arguments: .A = lfn/sa, .X = priority, .Y = device
; Returns: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Sets the logical file number, secondary address, and IEC device
; for a particular priority
;
; Must only be called from main loop routines.
;
; Calling this function is not necessary if you wish to use defaults
; that have been set at engine init:
;
; Priority 0: lfn/sa 11, device 8
; Priority 1: lfn/sa 12, device 8
; Priority 2: lfn/sa 13, device 8
; Priority 3: lfn/sa 14, device 8
.proc zsm_setlfs: near
	PRESERVE_BANK_NO_CLOBBER
	sta streaming_lfn_sa,x
	tya
	sta streaming_dev,x
	RESTORE_BANK
	rts
.endproc

;..............
; zsm_setfile :
;============================================================================
; Arguments: .X = priority, .A .Y = null terminated filename pointer
; Returns: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Sets the filename for the priority, opens it, and parses the header
;
; Must only be called from main loop routines.
.proc zsm_setfile: near
	sta ZSF1
	sty ZSF1+1
	PRESERVE_BANK_CLOBBER_A_P

	lda times_fn_max_length,x
	clc
	adc #<streaming_filename
	sta ZSF2
	lda #>streaming_filename
	adc #0
	sta ZSF2+1
	ldy #0
loop:
	lda $ffff,y
ZSF1 = *-2
	beq done
	sta $ffff,y
ZSF2 = *-2
	iny
	bne loop
done:
	tya
	sta streaming_filename_len,x
	stz prio_playable,x

	jsr _open_and_parse
	RESTORE_BANK
	rts
.endproc

;..................
; _open_and_parse :
;============================================================================
; Arguments: .X = priority
; Returns: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; internal function that opens the associated file and, and parses the header
;
; Must only be called from main loop routines.

.proc _open_and_parse: near
	stx prio

	stz streaming_loop_point_l,x
	stz streaming_loop_point_m,x
	stz streaming_loop_point_h,x

	jsr _open_zsm
	bcc :+
	jmp exit
:
	; parse header
	lda streaming_lfn_sa,x
	tax
	jsr X16::Kernal::CHKIN

	jsr X16::Kernal::BASIN
	cmp #$7a ; 'z'
	bne err2

	jsr X16::Kernal::BASIN
	cmp #$6d ; 'm'
	bne err2

	jsr X16::Kernal::BASIN
	cmp #1 ; expected version number
	beq noerr2
err2:
	jmp error
noerr2:

	; loop point
	ldx prio
	jsr X16::Kernal::BASIN
	sta streaming_loop_point_l,x
	jsr X16::Kernal::BASIN
	sta streaming_loop_point_m,x
	jsr X16::Kernal::BASIN
	sta streaming_loop_point_h,x

	; PCM offset, ignore
	jsr X16::Kernal::BASIN
	jsr X16::Kernal::BASIN
	jsr X16::Kernal::BASIN

	; FM channel mask
	jsr X16::Kernal::BASIN
	ldy prio
	ldx times_8,y
.repeat 8,i
	lsr
	stz opm_voice_mask+i,x
	ror opm_voice_mask+i,x
.endrepeat

	; PSG channel mask
	jsr X16::Kernal::BASIN
	ldx times_16,y
.repeat 8,i
	lsr
	stz vera_psg_voice_mask+i,x
	ror vera_psg_voice_mask+i,x
.endrepeat
	jsr X16::Kernal::BASIN
.repeat 8,i
	lsr
	stz vera_psg_voice_mask+i+8,x
	ror vera_psg_voice_mask+i+8,x
.endrepeat

	; ZSM tick rate
	jsr X16::Kernal::BASIN
	sta tick_rate_l,y
	jsr X16::Kernal::BASIN
	sta tick_rate_h,y

	; two reserved bytes
	jsr X16::Kernal::BASIN
	jsr X16::Kernal::BASIN

	jsr X16::Kernal::CLRCHN

	; finish setup of state
	ldx prio
	stz delay_f,x
	stz delay_l,x
	stz delay_h,x

	stz ringbuffer_start_l,x
	stz ringbuffer_end_l,x
	lda ringbuffer_start_page,x
	sta ringbuffer_start_h,x
	sta ringbuffer_end_h,x

	; non-zero loop point sets loop_enable
	lda streaming_loop_point_l,x
	ora streaming_loop_point_m,x
	ora streaming_loop_point_h,x
	cmp #1
	stz loop_enable,x
	ror loop_enable,x

	lda #$80
	sta streaming_mode,x
	sta prio_playable,x

	lda zsmkit_bank
	sta zsm_ptr_bank,x

	jsr _calculate_speed ; X = prio

exit:
	rts
error:
	jsr X16::Kernal::CLRCHN
	ldx prio
	lda streaming_lfn_sa,x
	jsr X16::Kernal::CLOSE
	ldx prio
	lda #$80
	sta streaming_finished,x
	sta recheck_priorities
	stz prio_playable,x
	sec
	bra exit
prio:
	.byte 0
.endproc

;............
; _open_zsm :
;============================================================================
; Arguments: .X = priority
; Returns: .C set for error
; Preserves: .X
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; This internal routine (re-)opens a ZSM file for use in streaming mode.
; If it's the first time the file is opened, streaming_loop_point_[lmh],x
; must be zeroed first so that the seek points to the beginning of the file. 
;
; Must only be called from main loop routines.
.proc _open_zsm: near

	stx prio ; save priority locally

	; make sure handle (lfn) is closed
	lda streaming_lfn_sa,x
	jsr X16::Kernal::CLOSE
	ldx prio


	ldy streaming_filename_len,x
	phy ; save filename length
	lda times_fn_max_length,x
	clc
	adc #<streaming_filename
	sta FP
	lda #>streaming_filename
	adc #0
	sta FP+1
	dey
fnloop:
	lda $ffff,y
FP = *-2
	sta buff,y
	dey
	bpl fnloop

	ldx #<buff
	ldy #>buff
	pla ; restore filename length
	jsr X16::Kernal::SETNAM

	ldx prio
	ldy streaming_lfn_sa,x
	lda streaming_dev,x
	tax
	tya
	jsr X16::Kernal::SETLFS

	jsr X16::Kernal::OPEN

	; seek to loop point
	ldx prio
	lda streaming_lfn_sa,x
	sta seekpoint+1
	lda streaming_loop_point_l,x
	sta seekpoint+2
	lda streaming_loop_point_m,x
	sta seekpoint+3
	lda streaming_loop_point_h,x
	sta seekpoint+4

	lda #6
	ldx #<seekpoint
	ldy #>seekpoint

	jsr X16::Kernal::SETNAM

	ldx prio
	lda streaming_dev,x
	tax
	lda #15
	tay
	jsr X16::Kernal::SETLFS

	jsr X16::Kernal::OPEN

	ldx #15
	jsr X16::Kernal::CHKIN
	jsr X16::Kernal::BASIN
	pha ; preserve byte read
	jsr X16::Kernal::READST
	and #$40
	bne errorp
	pla ; restore byte read from command channel
	beq errord
	cmp #'0'
	bne error
	jsr X16::Kernal::CLRCHN
	lda #15
	jsr X16::Kernal::CLOSE
	ldx prio
	clc
	rts
errord:
	dec
	pha
errorp:
	ply
error:
	jsr X16::Kernal::CLRCHN
	lda #15
	jsr X16::Kernal::CLOSE
	ldx prio
	lda #$80
	sta streaming_finished,x
	sta recheck_priorities
	stz prio_playable,x
	sec	
	rts
prio:
	.byte 0
seekpoint:
	.byte 'P', $00, $00, $00, $00, $00
.endproc

.endif

;.............
; zsm_setmem :
;============================================================================
; Arguments: .X = priority, .A .Y = data pointer, $00 = ram bank
; Returns: (none)
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; Sets the start of memory for the priority, reads it,
; and parses the header
;
; Must only be called from main loop routines.
.proc zsm_setmem: near
	sta ZM1
	sta buff+16
	sty ZM1+1
	sty buff+17
	lda X16::Reg::RAMBank
	sta buff+18

	PRESERVE_BANK_CLOBBER_A_P

	stx prio
	lda prio_active,x
	beq :+

	RESTORE_BANK

	jsr zsm_close ; will also stop
:	RESTORE_BANK
	ldy #0
hdrloop: ; copy the header to our low ram buffer
	lda $ffff
ZM1 = *-2
	sta buff,y
	inc ZM1
	bne :+
	inc ZM1+1
:	lda ZM1+1
	cmp #$c0
	bcc :+
	sbc #$20
	sta ZM1+1
	inc X16::Reg::RAMBank
:	iny
	cpy #16
	bcc hdrloop

	ldy zsmkit_bank ; switch back to our bank and copy the values out of the buffer into the state
	sty X16::Reg::RAMBank

	ldx prio
	lda buff+18
	sta zsm_start_bank,x
	sta zsm_ptr_bank,x
	lda ZM1
	sta zsm_start_l,x
	sta zsm_ptr_l,x
	lda ZM1+1
	sta zsm_start_h,x
	sta zsm_ptr_h,x

	lda buff
	cmp #$7a ; 'z'
	bne err1

	lda buff+1
	cmp #$6d ; 'm'
	bne err1

	lda buff+2 ; version (1)
	cmp #1
	beq noerr1

err1:
	stz prio_playable,x
	sec
	rts

noerr1:

	lda buff+5 ; loop point [23:16]
	asl        ; each of these is
	asl        ; worth 64 k
	asl        ; or 8 banks
	clc
	adc buff+18 ; start bank
	sta zsm_loop_bank,x

	lda buff+4 ; loop point [15:8]
	lsr        ; each of these
	lsr        ; is worth a page
	lsr        ; and 32 of them
	lsr        ; is worth
	lsr        ; one 8k bank
	clc
	adc zsm_loop_bank,x
	sta zsm_loop_bank,x

	lda buff+4 ; keep the remainder
	and #$1f   ; which when added to the start
	sta buff+19 ; will be < $ff

	lda buff+3 ; loop point [7:0]
	clc
	adc buff+16 ; start of zsm data (LSB)
	sta zsm_loop_l,x
	lda buff+19 ; loop point [12:8]
	adc buff+17 ; start of zsm data (MSB)
:	cmp #$c0    ; if we're past
	bcc :+
	sbc #$20    ; subtract $20
	inc zsm_loop_bank,x ; and increment bank
	bra :-
:	sta zsm_loop_h,x ; and we're done figuring out the loop point


	lda buff+3  ; but do we even loop at all?
	ora buff+4
	ora buff+5
	cmp #1
	stz loop_enable,x
	ror loop_enable,x

	; ignore buff offset 6 7 8 (PCM offset)

	; FM channel mask
	lda buff+9
	ldy prio
	ldx times_8,y
.repeat 8,i
	lsr
	stz opm_voice_mask+i,x
	ror opm_voice_mask+i,x
.endrepeat

	; PSG channel mask
	lda buff+10
	ldx times_16,y
.repeat 8,i
	lsr
	stz vera_psg_voice_mask+i,x
	ror vera_psg_voice_mask+i,x
.endrepeat
	lda buff+11
.repeat 8,i
	lsr
	stz vera_psg_voice_mask+i+8,x
	ror vera_psg_voice_mask+i+8,x
.endrepeat

	; ZSM tick rate
	lda buff+12
	sta tick_rate_l,y
	lda buff+13
	sta tick_rate_h,y

	; 14 and 15 are reserved bytes
	; finish setup of state
	ldx prio
	stz delay_f,x
	stz delay_l,x
	stz delay_h,x	

.ifdef ZSMKIT_ENABLE_STREAMING
	stz streaming_mode,x
.endif
	lda #$80
	sta prio_playable,x

	jsr _calculate_speed

	RESTORE_BANK
	rts
prio:
	.byte 0
.endproc

;...................
; _calculate_speed :
;============================================================================
; Arguments: .X = priority
; Returns: (none)
; Preserves: .X
; Allowed in interrupt handler: no
; ---------------------------------------------------------------------------
;
; performs the calculation tick_rate_*/60 and stores in speed_*
;
.proc _calculate_speed: near
	stx prio
	; set speed to 60 if ZSM says it's zero
	lda tick_rate_l,x
	ora tick_rate_h,x
	bne :+
	lda #60
	sta tick_rate_l,x
:	
	; initialize remainder to 0
	stz tmp1
	stz tmp1+1
	; dividend = tick_rate*256
	; so that the quotient is a 16.8 fixed point result
	stz tmp2
	lda tick_rate_l,x
	sta tmp2+1
	lda tick_rate_h,x
	sta tmp2+2
	; initialize divisor to 60
	lda #60
	sta tmp3
	stz tmp3+1

	; 24 bits in the dividend
	ldx #24
l1:
	asl tmp2
	rol tmp2+1
	rol tmp2+2
	rol tmp1
	rol tmp1+1
	lda tmp1
	sec
	sbc tmp3
	tay
	lda tmp1+1
	sbc tmp3+1
	bcc l2
	sta tmp1+1
	sty tmp1
	inc tmp2
l2:
	dex
	bne l1

	ldx prio
	lda tmp2
	sta speed_f,x
	lda tmp2+1
	sta speed_l,x
	lda tmp2+2
	sta speed_h,x

	rts
prio:
	.byte 0
.endproc



.proc _print_hex: near
	pha
	lsr
	lsr
	lsr
	lsr
	tay
	lda table,y	
	jsr X16::Kernal::BSOUT

	pla
	and #$0f
	tay
	lda table,y	
	jsr X16::Kernal::BSOUT

	rts

table:
	.byte "0123456789ABCDEF"
.endproc

.ifdef ZSMKIT_ENABLE_STREAMING
ringbuffer_start_page:
.repeat NUM_PRIORITIES, i
	.byte $A0+(i*(RINGBUFFER_SIZE >> 8))
.endrepeat

ringbuffer_end_page: ; non-inclusive
.repeat NUM_PRIORITIES, i
	.byte $A0+((i+1)*(RINGBUFFER_SIZE >> 8))
.endrepeat
.endif

times_fn_max_length:
.repeat NUM_PRIORITIES, i
	.byte i*FILENAME_MAX_LENGTH
.endrepeat

times_8:
.repeat NUM_PRIORITIES, i
	.byte i*8
.endrepeat

times_16:
.repeat NUM_PRIORITIES, i
	.byte i*16
.endrepeat

times_64:
.repeat NUM_PRIORITIES, i
	.byte i*64
.endrepeat

rr_m1:
.repeat 8, i
	.byte $e0+i
.endrepeat

rr_m2:
.repeat 8, i
	.byte $e8+i
.endrepeat

rr_c1:
.repeat 8, i
	.byte $f0+i
.endrepeat

rr_c2:
.repeat 8, i
	.byte $f8+i
.endrepeat