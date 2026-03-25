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
    mov64 r8, r1                    ; save input buffer ptr

    ; Compute offset adjustment: counter data section may be 0 or 8 bytes,
    ; shifting all offsets after COUNTER_DATA (SYSTEM_PROGRAM_*, INSTRUCTION_DATA*).
    ; COUNTER_DATA_LEN is at a fixed position (before the variable data section).
    ldxdw r7, [r8 + COUNTER_DATA_LEN]   ; r7 = counter data_len (0 for create, 8 for inc/dec)
    add64 r7, 7
    and64 r7, -8                    ; r7 = counter_data_len rounded up to 8 (offset adjustment)

    ; Check instruction data length (with adjustment)
    mov64 r6, r8
    add64 r6, INSTRUCTION_DATA_LEN
    add64 r6, r7
    ldxdw r4, [r6 + 0]
    jne r4, 2, error_invalid_instruction

    ##########################
    ##     Prepare seeds    ##
    ##########################

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

    ; seed[2] = {bump, 1}  — bump stored at r9+48 (at INSTRUCTION_DATA+1, adjusted)
    mov64 r6, r8
    add64 r6, INSTRUCTION_DATA
    add64 r6, r7
    ldxb r6, [r6 + 1]              ; load bump byte (adjusted)
    stxb [r9 + 48], r6             ; store bump byte on stack
    mov64 r6, r9
    add64 r6, 48
    stxdw [r9 + 32], r6            ; seed[2].addr = ptr to bump byte
    mov64 r6, 1
    stxdw [r9 + 40], r6            ; seed[2].len  = 1

    ##########################
    ##      PDA check       ##
    ##########################

    ; r3 = program_id ptr (INSTRUCTION_DATA + 2, adjusted)
    mov64 r3, r8
    add64 r3, INSTRUCTION_DATA
    add64 r3, 2
    add64 r3, r7

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
    mov64 r4, r9
    add64 r4, 88                    ; r4 = result ptr (i32 written here by syscall)
    call sol_memcmp_
    ldxw r6, [r9 + 88]
    jne r6, 0, error_invalid_pda

    ; load discriminator (INSTRUCTION_DATA, adjusted)
    mov64 r6, r8
    add64 r6, INSTRUCTION_DATA
    add64 r6, r7
    ldxb r6, [r6 + 0]
    jeq r6, 0x0, create
    jeq r6, 0x1, increment
    jeq r6, 0x2, decrement
    ja error_invalid_instruction

    exit


create:
    ##################################
    ## Build CreateAccount ix data  ##
    ##################################

    sub64 r9, 332
    mov64 r6, r9
    add64 r6, 96                            ; r6 = instruction data ptr (r9+96)

    mov64 r5, 0
    stxw [r6 + 0], r5                       ; discriminator = 0 (CreateAccount)
    mov64 r5, 890880
    stxdw [r6 + 4], r5                      ; lamports (rent-exempt for 8 bytes)
    mov64 r5, 8
    stxdw [r6 + 12], r5                     ; space = 8 bytes

    ; copy 32-byte program_id from instruction data into owner field
    ldxdw r5, [r8 + INSTRUCTION_DATA + 2]
    stxdw [r6 + 20], r5
    ldxdw r5, [r8 + INSTRUCTION_DATA + 10]
    stxdw [r6 + 28], r5
    ldxdw r5, [r8 + INSTRUCTION_DATA + 18]
    stxdw [r6 + 36], r5
    ldxdw r5, [r8 + INSTRUCTION_DATA + 26]
    stxdw [r6 + 44], r5                     ; owner = program_id (bytes 2-33 of ix data)


    #######################################
    ## Build CreateAccount Acount metas  ##
    #######################################

    ;payer meta at r9+148
    mov64 r5, r9
    add64 r5, 148
    mov64 r3, r8
    add64 r3, OWNER_KEY           ; pubkey ptr
    stxdw [r5 + 0], r3
    mov64 r3, 1
    stxb [r5 + 8], r3           ; is_writable
    mov64 r3, 1
    stxb [r5 + 9], r3           ; is_signer

    ; counter meta at r9+164
    mov64 r5, r9
    add64 r5, 164
    mov64 r3, r8
    add64 r3, COUNTER_KEY
    stxdw [r5 + 0], r3
    mov64 r3, 1
    stxb [r5 + 8], r3           ; is_writable
    mov64 r3, 1
    stxb [r5 + 9], r3           ; is_signer

    #########################################
    ##   Build CreateAccount Instruction   ##
    #########################################

    mov64 r7, r9
    add64 r7, 180               ; r7 = instruction ptr

    mov64 r3, r8
    add64 r3, SYSTEM_PROGRAM_KEY
    stxdw [r7 + 0], r3          ; program_id ptr
    mov64 r3, r9
    add64 r3, 148
    stxdw [r7 + 8], r3          ; account metas ptr (r9+148)
    mov64 r3, 2
    stxdw [r7 + 16], r3         ; num_accounts
    stxdw [r7 + 24], r6         ; instruction data ptr (r9 + 96)
    mov64 r3, 52
    stxdw [r7 + 32], r3         ; data_len

    #########################################
    ##       Build Sol Account Infos       ##
    #########################################

    mov64 r6, r9
    add64 r6, 220               ; r6 = account infos ptr (r9+220)

    ; payer/owner info at r9+220
    mov64 r3, r8
    add64 r3, OWNER_KEY
    stxdw [r6 + 0], r3         ; owner key ptr
    mov64 r3, r8
    add64 r3, OWNER_LAMPORTS
    stxdw [r6 + 8], r3         ; owner lamports ptr
    ldxdw r3, [r8 + OWNER_DATA_LEN]
    stxdw [r6 + 16], r3        ; owner data len
    mov64 r3, r8
    add64 r3, OWNER_DATA
    stxdw [r6 + 24], r3        ; owner data ptr
    mov64 r3, r8
    add64 r3, OWNER_OWNER
    stxdw [r6 + 32], r3        ; owner owner ptr
    ldxdw r3,  [r8 + OWNER_RENT_EPOCH]
    stxdw [r6 + 40], r3        ; owner rent epoch
    ldxb r3, [r8 + OWNER_HEADER + 1]
    stxb [r6 + 48], r3        ; is_signer
    ldxb r3, [r8 + OWNER_HEADER + 2]
    stxb [r6 + 49], r3        ; is_writable
    ldxb r3, [r8 + OWNER_HEADER + 3]
    stxb [r6 + 50], r3        ; is_executable


    add64 r6, 56               ; r6 = counter account info
    ; counter info at r9+276
    mov64 r3, r8
    add64 r3, COUNTER_KEY
    stxdw [r6 + 0], r3         ; counter key ptr
    mov64 r3, r8
    add64 r3, COUNTER_LAMPORTS
    stxdw [r6 + 8], r3         ; counter lamports ptr
    ldxdw r3, [r8 + COUNTER_DATA_LEN]
    stxdw [r6 + 16], r3        ; counter data len
    mov64 r3, r8
    add64 r3, COUNTER_DATA
    stxdw [r6 + 24], r3        ; counter data ptr
    mov64 r3, r8
    add64 r3, COUNTER_OWNER
    stxdw [r6 + 32], r3        ; counter owner ptr
    ldxdw r3,  [r8 + COUNTER_RENT_EPOCH]
    stxdw [r6 + 40], r3        ; counter rent epoch
    ldxb r3, [r8 + COUNTER_HEADER + 1]
    stxb [r6 + 48], r3        ; is_signer
    ldxb r3, [r8 + COUNTER_HEADER + 2]
    stxb [r6 + 49], r3        ; is_writable
    ldxb r3, [r8 + COUNTER_HEADER + 3]
    stxb [r6 + 50], r3        ; is_executable


    #########################################
    ##       Call CreateAccount CPI        ##
    #########################################

    ; signer seeds wrapper at r9+52
    mov64 r3, r9
    add64 r3, 332
    stxdw [r9 + 52], r3    ; ptr to seeds array (r9+0)
    mov64 r3, 3
    stxdw [r9 + 60], r3    ; num seeds

    ; call sol_invoke_signed_c
    mov64 r1, r7            ; SolInstruction (r9+180)
    mov64 r2, r9
    add64 r2, 220           ; account infos (r9+220)
    mov64 r3, 2             ; num account infos
    mov64 r4, r9
    add64 r4, 52            ; signer seeds wrapper
    mov64 r5, 1             ; num signers
    call sol_invoke_signed_c

    jne r0, 0, error_create_failed
    mov64 r0, 0

    exit

increment:
    ;OWNER CHECK - IS ACCOUNT INITIALIZED
    mov64 r1, r8
    add64 r1, COUNTER_OWNER         ; r1 = counter owner ptr
    mov64 r2, r8
    add64 r2, INSTRUCTION_DATA
    add64 r2, 2
    add64 r2, r7                    ; r2 = program_id ptr (adjusted)
    mov64 r3, 32
    mov64 r4, r9
    add64 r4, 88                    ; r4 = result ptr
    call sol_memcmp_
    ldxw r6, [r9 + 88]
    jne r6, 0, error_not_initialized

    ;DATA LENGTH CHECK
    ldxdw r6, [r8 + COUNTER_DATA_LEN]
    jne r6, 8, error_invalid_data_len

    ;OVERFLOW CHECK
    ldxdw r2, [r8 + COUNTER_DATA]
    lddw r6, 0xffffffffffffffff
    jeq r2, r6, error_overflow

    add64 r2, 1
    stxdw [r8 + COUNTER_DATA], r2
    mov64 r0, 0
    exit

decrement:
    ;OWNER CHECK - IS ACCOUNT INITIALIZED
    mov64 r1, r8
    add64 r1, COUNTER_OWNER         ; r1 = counter owner ptr
    mov64 r2, r8
    add64 r2, INSTRUCTION_DATA
    add64 r2, 2
    add64 r2, r7                    ; r2 = program_id ptr (adjusted)
    mov64 r3, 32
    mov64 r4, r9
    add64 r4, 88                    ; r4 = result ptr
    call sol_memcmp_
    ldxw r6, [r9 + 88]
    jne r6, 0, error_not_initialized

    ;DATA LENGTH CHECK
    ldxdw r6, [r8 + COUNTER_DATA_LEN]
    jne r6, 8, error_invalid_data_len

    ;UNDERFLOW CHECK
    ldxdw r2, [r8 + COUNTER_DATA]
    jeq r2, 0, error_underflow

    sub64 r2, 1
    stxdw [r8 + COUNTER_DATA], r2
    mov64 r0, 0
    exit

error_invalid_data_len:
    lddw r1, invalid_data_len_error_log
    mov64 r2, 16
    call sol_log_
    lddw r0, 0xf
    exit
error_overflow:
    lddw r1, overflow_error_log
    mov64 r2, 8
    call sol_log_
    lddw r0, 0x10
    exit
error_underflow:
    lddw r1, underflow_error_log
    mov64 r2, 9
    call sol_log_
    lddw r0, 0x11
    exit

error_create_failed:
    lddw r1, create_account_error_log
    mov64 r2, 21
    call sol_log_
    lddw r0, 0xd
    exit

error_invalid_pda:
    lddw r1, invalid_pda_error_log
    mov64 r2, 11
    call sol_log_
    lddw r0, 0xc
    exit

error_not_initialized:
    lddw r1, not_initialized_error_log
    mov64 r2, 15
    call sol_log_
    lddw r0, 0xe
    exit

error_invalid_instruction:
    lddw r1, invalid_instruction_error_log
    mov64 r2, 19
    call sol_log_
    lddw r0, 0xb
    exit


.rodata
    invalid_pda_error_log: .ascii "Invalid PDA"
    invalid_instruction_error_log: .ascii "Invalid instruction"
    create_account_error_log: .ascii "Create account failed"
    invalid_data_len_error_log: .ascii "Invalid data len"
    overflow_error_log: .ascii "Overflow"
    underflow_error_log: .ascii "Underflow"
    not_initialized_error_log: .ascii "Not initialized"
    counter_seed: .ascii "counter"
