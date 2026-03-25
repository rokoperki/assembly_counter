# Assembly Counter

A Solana counter program written in raw SBF (Solana BPF) assembly. No Rust, no Anchor — just hand-written eBPF instructions.

## What it does

Stores a `u64` counter in a PDA account. Supports three instructions:

| Discriminator | Instruction | Description |
|---|---|---|
| `0x00` | `create` | Creates the counter PDA account via CPI to System Program |
| `0x01` | `increment` | Increments the counter by 1 |
| `0x02` | `decrement` | Decrements the counter by 1 |

## Accounts

All instructions take the same three accounts in order:

1. **payer** — writable, signer. Funds account creation.
2. **counter PDA** — writable. Derived from `["counter", payer_pubkey]`.
3. **system program** — read-only.

## Instruction data

All instructions use exactly 2 bytes:

```
[discriminator: u8, bump: u8]
```

The program ID follows immediately after the instruction data in the Solana input buffer (standard serialization) and is used for PDA derivation and owner verification.

## PDA

The counter account is a PDA derived from:

```
seeds = ["counter", payer_pubkey, bump]
program_id = <this program>
```

## Checks

- **Instruction data length** — must be exactly 2 bytes
- **PDA validation** — derived address must match the counter account key
- **Owner check** (increment/decrement) — counter account must be owned by this program
- **Data length check** (increment/decrement) — counter account data must be exactly 8 bytes
- **Overflow protection** — increment errors at `u64::MAX`
- **Underflow protection** — decrement errors at `0`

## Error codes

| Code | Description |
|---|---|
| `0x0b` (11) | Invalid instruction data length |
| `0x0c` (12) | Invalid PDA |
| `0x0d` (13) | Create account failed |
| `0x0e` (14) | Counter not initialized (wrong owner) |
| `0x0f` (15) | Invalid counter data length |
| `0x10` (16) | Overflow |
| `0x11` (17) | Underflow |

## Build

Requires the Solana SBF toolchain.

```bash
cargo build-sbf
```

## Test

```bash
cargo test
```

Tests use [mollusk-svm](https://github.com/buffalojoec/mollusk) to execute the program in an in-process SVM without a validator.

## Tracing

`trace.txt.0` contains a full execution trace of the `create` instruction. Each line shows the assembly instruction being executed along with the register state at that point — useful for stepping through the logic and verifying register values.

To generate a trace yourself:

```bash
agave-ledger-tool program run deploy/assembly_counter.so \
  --ledger test-ledger \
  --mode interpreter \
  --input src/assembly_counter/instructions.json \
  --trace trace.txt
```

**Note:** `agave-ledger-tool` must be version `2.x.x`. The `program run` command was removed in later versions.

The input for the trace is defined in `src/assembly_counter/instructions.json` — it describes the accounts and instruction data for a `create` call.

Each line in the trace file looks like this:

```
<step> [r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10]   <pc>: <instruction>
```

For example:

```
 0 [0000000000000000, 0000000400000000, ...]     0: mov64 r8, r1
 1 [0000000000000000, 0000000400000000, ...]     1: ldxdw r7, [r8+0x28b8]
 2 [...]                                         2: add64 r7, 7
 3 [... 0000000000000007, ...]                   3: and64 r7, -8
 8 [... 0000000000000002, ...]                   8: jne r4, 2, lbb_255
```

Reading left to right: the step counter, then 11 register values (`r0`–`r10`) showing the state **before** the instruction executes, then the program counter and the instruction itself. You can watch a value appear in a register on the line after the instruction that wrote it.

## How the program works

### Register conventions

SBF has 11 registers. The program uses them as follows:

- `r1` — entry: input buffer pointer (Solana passes this). Clobbered by every syscall.
- `r8` — saved input buffer pointer (persists across syscalls)
- `r9` — stack frame pointer (r10 - offset). Used like a local variable base.
- `r10` — hardware frame pointer, read-only
- `r7` — offset adjustment for dynamic input buffer layout (see below)
- `r6`, `r5`, `r3`, `r4`, `r2` — scratch registers for building structs and syscall args

### Input buffer layout

When Solana calls the program, `r1` points to a serialized input buffer:

```
[num_accounts: u64]
[account 0 header + key + owner + lamports + data_len + data + rent_epoch]
[account 1 ...]
[account 2 ...]
[instruction_data_len: u64]
[instruction_data: bytes]
[program_id: [u8; 32]]
```

Each account's data section is padded to `data_len + 10240` bytes (to allow in-place data growth). This means all offsets after an account's data section shift when its data length changes. All `.equ` constants at the top of the file are pre-computed byte offsets into this buffer.

### Dynamic offset adjustment

The counter account can have 0 bytes of data (during `create`) or 8 bytes (during `increment`/`decrement`). This shifts `INSTRUCTION_DATA_LEN` and `INSTRUCTION_DATA` by 8 bytes between the two cases.

At the start of every call, the program reads `COUNTER_DATA_LEN` (which is at a fixed position, before the variable data section), rounds it up to the nearest 8 bytes, and stores the adjustment in `r7`. Every access to `INSTRUCTION_DATA` adds `r7` to the offset.

### Stack layout (entrypoint frame, 96 bytes)

The entrypoint allocates a 96-byte stack frame (`sub64 r9, 96`) used for:

```
r9+0  to r9+47  — SolSignerSeed array (3 seeds × 16 bytes)
r9+48           — bump byte (1 byte, pointed to by seed[2])
r9+52 to r9+67  — SolSignerSeeds wrapper (ptr + count) for sol_invoke_signed_c
r9+56 to r9+87  — 32-byte output buffer for sol_create_program_address
r9+88 to r9+91  — i32 result buffer for sol_memcmp_
```

The `create` handler allocates an additional 332 bytes (`sub64 r9, 332`) below the entrypoint frame for the CPI structs: `SolInstruction`, two `SolAccountMeta`, and two `SolAccountInfo`.

### PDA validation

Every call validates the counter PDA before branching to an instruction handler:

1. Build seeds array on stack: `["counter", payer_key, [bump]]`
2. Call `sol_create_program_address` — derives the expected PDA into a stack buffer
3. Call `sol_memcmp_` — compares derived address with the counter key from the input buffer
4. If they differ, return `error_invalid_pda`

`sol_memcmp_` does **not** return the comparison result in `r0`. It writes an `i32` to the pointer in `r4`. `r0` is only a syscall success code (always 0 if the syscall itself succeeded). The program reads the result from the stack after the call.

### CPI for `create`

The `create` handler builds the following structs on the stack and calls `sol_invoke_signed_c`:

- **Instruction data** (52 bytes): System Program `CreateAccount` discriminator, lamports (890880, rent-exempt for 8 bytes), space (8), owner (program_id)
- **SolAccountMeta** × 2: payer (writable, signer) + counter PDA (writable, signer)
- **SolInstruction**: system program key, account metas ptr, count, data ptr, data len
- **SolAccountInfo** × 2: full account info structs for payer and counter, copied from the input buffer
- **SolSignerSeeds**: pointer to the seeds array + seed count

The counter PDA must have `is_signer=1` in the account meta, and the signer seeds must match it. The runtime verifies the seeds derive to the counter PDA before authorizing the signature.

### `increment` / `decrement`

These handlers do no CPI. They:

1. Compare `COUNTER_OWNER` against the program ID — rejects uninitialised accounts
2. Check `COUNTER_DATA_LEN == 8`
3. Check for overflow (`u64::MAX`) or underflow (`0`)
4. Load the `u64` from `COUNTER_DATA`, add/subtract 1, store back

The counter value is stored as a little-endian `u64` directly in the account's data region.
