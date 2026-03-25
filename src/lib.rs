#[cfg(test)]
mod tests {
    use mollusk_svm::{program::keyed_account_for_system_program, result::Check, Mollusk};
    use solana_account::Account;
    use solana_address::Address;
    use solana_instruction::{AccountMeta, Instruction};
    use solana_program_error::ProgramError;
    use solana_pubkey::Pubkey;

    #[test]
    fn test_create() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);

        let (system_program_key, system_program_account) = keyed_account_for_system_program();

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[0, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(2_000_000_000, 0, &system_program_key)),
                (counter_pda, Account::new(0, 0, &system_program_key)),
                (system_program_key, system_program_account),
            ],
            &[Check::success()],
        );
    }

    #[test]
    fn test_create_wrong_instruction_length() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, _bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);

        let (system_program_key, system_program_account) = keyed_account_for_system_program();

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        // only 1 byte — program expects exactly 2
        let instruction = Instruction::new_with_bytes(
            program_id,
            &[0],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(2_000_000_000, 0, &system_program_key)),
                (counter_pda, Account::new(0, 0, &system_program_key)),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0xb))],
        );
    }

    #[test]
    fn test_create_wrong_pda() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (_counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let wrong_pda = Pubkey::new_unique(); // not the real PDA

        let (system_program_key, system_program_account) = keyed_account_for_system_program();

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        // correct bump, but wrong account passed as counter — memcmp will always fail
        let instruction = Instruction::new_with_bytes(
            program_id,
            &[0, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(wrong_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(2_000_000_000, 0, &system_program_key)),
                (wrong_pda, Account::new(0, 0, &system_program_key)),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0xc))],
        );
    }

    #[test]
    fn test_create_already_exists() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);

        let (system_program_key, system_program_account) = keyed_account_for_system_program();

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[0, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        // counter already has lamports — system program will reject CreateAccount
        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(2_000_000_000, 0, &system_program_key)),
                (counter_pda, Account::new(890_880, 0, &system_program_key)),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0))],
        );
    }

    fn setup_initialized_counter(
        program_id_bytes: [u8; 32],
        value: u64,
    ) -> (Pubkey, Account) {
        let owner = Pubkey::new_from_array(program_id_bytes);
        let mut account = Account::new(890_880, 8, &owner);
        account.data = value.to_le_bytes().to_vec();
        (owner, account)
    }

    #[test]
    fn test_increment() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let (system_program_key, system_program_account) = keyed_account_for_system_program();
        let (_, counter_account) = setup_initialized_counter(program_id_keypair_bytes, 0);

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[1, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(1_000_000_000, 0, &system_program_key)),
                (counter_pda, counter_account),
                (system_program_key, system_program_account),
            ],
            &[
                Check::success(),
                Check::account(&counter_pda).data(&1u64.to_le_bytes()).build(),
            ],
        );
    }

    #[test]
    fn test_increment_not_initialized() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let (system_program_key, system_program_account) = keyed_account_for_system_program();

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[1, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        // counter owned by system program — not initialized
        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(1_000_000_000, 0, &system_program_key)),
                (counter_pda, Account::new(0, 8, &system_program_key)),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0xe))],
        );
    }

    #[test]
    fn test_increment_overflow() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let (system_program_key, system_program_account) = keyed_account_for_system_program();
        let (_, counter_account) = setup_initialized_counter(program_id_keypair_bytes, u64::MAX);

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[1, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(1_000_000_000, 0, &system_program_key)),
                (counter_pda, counter_account),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0x10))],
        );
    }

    #[test]
    fn test_decrement() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let (system_program_key, system_program_account) = keyed_account_for_system_program();
        let (_, counter_account) = setup_initialized_counter(program_id_keypair_bytes, 5);

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[2, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(1_000_000_000, 0, &system_program_key)),
                (counter_pda, counter_account),
                (system_program_key, system_program_account),
            ],
            &[
                Check::success(),
                Check::account(&counter_pda).data(&4u64.to_le_bytes()).build(),
            ],
        );
    }

    #[test]
    fn test_decrement_not_initialized() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let (system_program_key, system_program_account) = keyed_account_for_system_program();

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[2, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(1_000_000_000, 0, &system_program_key)),
                (counter_pda, Account::new(0, 8, &system_program_key)),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0xe))],
        );
    }

    #[test]
    fn test_decrement_underflow() {
        let program_id_keypair_bytes: [u8; 32] =
            std::fs::read("deploy/assembly_counter-keypair.json").unwrap()[..32]
                .try_into()
                .expect("slice with incorrect length");
        let program_id = Address::new_from_array(program_id_keypair_bytes);

        let payer = Pubkey::new_unique();
        let (counter_pda, bump) =
            Pubkey::find_program_address(&[b"counter", payer.as_ref()], &program_id);
        let (system_program_key, system_program_account) = keyed_account_for_system_program();
        let (_, counter_account) = setup_initialized_counter(program_id_keypair_bytes, 0);

        let mollusk = Mollusk::new(&program_id, "deploy/assembly_counter");

        let instruction = Instruction::new_with_bytes(
            program_id,
            &[2, bump],
            vec![
                AccountMeta::new(payer, true),
                AccountMeta::new(counter_pda, false),
                AccountMeta::new_readonly(system_program_key, false),
            ],
        );

        mollusk.process_and_validate_instruction(
            &instruction,
            &[
                (payer, Account::new(1_000_000_000, 0, &system_program_key)),
                (counter_pda, counter_account),
                (system_program_key, system_program_account),
            ],
            &[Check::err(ProgramError::Custom(0x11))],
        );
    }
}
