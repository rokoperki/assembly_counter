.equ NUM_ACCOUNTS, 0x0000

.equ OWNER_HEADER, 0x0008
.equ OWNER_KEY, 0x0010
.equ OWNER_OWNER, 0x0030
.equ OWNER_LAMPORTS, 0x0050
.equ OWNER_DATA_LEN, 0x0058
.equ OWNER_DATA, 0x0060
.equ OWNER_RENT_EPOCH, 0x2860

.equ COUNTER_HEADER, 0x2868
.equ COUNTER_KEY, 0x2870
.equ COUNTER_OWNER, 0x2890
.equ COUNTER_LAMPORTS, 0x28b0
.equ COUNTER_DATA_LEN, 0x28b8
.equ COUNTER_DATA, 0x28c0
.equ COUNTER_RENT_EPOCH, 0x50c0

.equ SYSTEM_PROGRAM_HEADER, 0x50c8
.equ SYSTEM_PROGRAM_KEY, 0x50d0
.equ SYSTEM_PROGRAM_OWNER, 0x50f0
.equ SYSTEM_PROGRAM_LAMPORTS, 0x5110
.equ SYSTEM_PROGRAM_DATA_LEN, 0x5118
.equ SYSTEM_PROGRAM_DATA, 0x5120
.equ SYSTEM_PROGRAM_RENT_EPOCH, 0x7930

.equ INSTRUCTION_DATA_LEN, 0x7938
.equ INSTRUCTION_DATA, 0x7940


.globl entrypoint

entrypoint:
    ldxdw r4, [r1 + INSTRUCTION_DATA_LEN]
    jne r4, 2, error_invalid_instruction

    ##########################
    ##     Prepare seeds    ##
    ##########################

    mov64 r8, r1                    ; save input buffer ptr (r1 will be clobbered by syscall)

    mov64 r9, r10
    sub64 r9, 96

    ; seed[0] = {"counter", 7}
    lddw r6, counter_seed
    stxdw [r9 + 0], r6             ; seed[0].addr = ptr to "counter"
    mov64 r6, 7
    stxdw [r9 + 8], r6             ; seed[0].len  = 7

    ; seed[1] = {payer_key, 32}
    mov64 r6, r8
    add64 r6, OWNER_KEY
    stxdw [r9 + 16], r6            ; seed[1].addr = ptr to payer key in input buffer
    mov64 r6, 32
    stxdw [r9 + 24], r6            ; seed[1].len  = 32

    ; seed[2] = {bump, 1}  — bump stored at r9+48
    ldxb r6, [r8 + INSTRUCTION_DATA + 1]
    stxb [r9 + 48], r6             ; store bump byte on stack
    mov64 r6, r9
    add64 r6, 48
    stxdw [r9 + 32], r6            ; seed[2].addr = ptr to bump byte
    mov64 r6, 1
    stxdw [r9 + 40], r6            ; seed[2].len  = 1

    ##########################
    ##      PDA check       ##
    ##########################

    ; r3 = program_id ptr (follows instruction data in input buffer: INSTRUCTION_DATA + 2)
    mov64 r3, r8
    add64 r3, INSTRUCTION_DATA
    add64 r3, 2

    ; r4 = output buffer for derived address (r9 + 56, 32 bytes)
    mov64 r4, r9
    add64 r4, 56

    mov64 r1, r9                    ; r1 = seeds array ptr
    mov64 r2, 3                     ; r2 = num seeds
    call sol_create_program_address

    jne r0, 0, error_invalid_pda

    ; compare derived address (r9+56) with counter key (r8+COUNTER_KEY)
    mov64 r1, r9
    add64 r1, 56                    ; r1 = derived address
    mov64 r2, r8
    add64 r2, COUNTER_KEY           ; r2 = expected counter key
    mov64 r3, 32                    ; r3 = length
    call sol_memcmp_
    jne r0, 0, error_invalid_pda

    exit

error_invalid_pda:
    lddw r0, 0xc
    lddw r1, invalid_pda_error_log
    mov64 r2, 11
    call sol_log_
    exit

error_invalid_instruction:
    lddw r0, 0xb
    lddw r1, invalid_instruction_error_log
    mov64 r2, 19
    call sol_log_
    exit


.rodata
    invalid_pda_error_log: .ascii "Invalid PDA"
    invalid_instruction_error_log: .ascii "Invalid instruction"
    counter_seed: .ascii "counter"
