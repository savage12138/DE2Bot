LIBRARY IEEE;
LIBRARY ALTERA_MF;
LIBRARY LPM;

USE IEEE.STD_LOGIC_1164.ALL;
USE IEEE.STD_LOGIC_ARITH.ALL;
USE IEEE.STD_LOGIC_UNSIGNED.ALL;
USE ALTERA_MF.ALTERA_MF_COMPONENTS.ALL;
USE LPM.LPM_COMPONENTS.ALL;


ENTITY SCOMP IS
	PORT(
		CLOCK    : IN    STD_LOGIC;
		RESETN   : IN    STD_LOGIC;
		PCINT    : IN    STD_LOGIC_VECTOR( 3 DOWNTO 0);
		IO_WRITE : OUT   STD_LOGIC;
		IO_CYCLE : OUT   STD_LOGIC;
		IO_ADDR  : OUT   STD_LOGIC_VECTOR( 7 DOWNTO 0);
		IO_DATA  : INOUT STD_LOGIC_VECTOR(15 DOWNTO 0)
	);
END SCOMP;


ARCHITECTURE a OF SCOMP IS
	TYPE STATE_TYPE IS (
		RESET_PC, FETCH, DECODE,
		EX_LOAD, EX_STORE, EX_STORE2, EX_ILOAD, EX_ISTORE, EX_LOADI,
		EX_ADD, EX_SUB, EX_ADDI,
		EX_JUMP, EX_JNEG, EX_JPOS, EX_JZERO,
		EX_CALL, EX_RETURN, EX_RETI,
		EX_AND, EX_OR, EX_XOR, EX_SHIFT,
		EX_IN, EX_IN2, EX_OUT, EX_OUT2
	);

	TYPE STACK_TYPE IS ARRAY (0 TO 9) OF STD_LOGIC_VECTOR(10 DOWNTO 0);

	SIGNAL STATE        : STATE_TYPE;
	SIGNAL PC_STACK     : STACK_TYPE;
	SIGNAL IO_IN        : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL AC           : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL AC_SAVED     : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL AC_SHIFTED   : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL IR           : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL MDR          : STD_LOGIC_VECTOR(15 DOWNTO 0);
	SIGNAL PC           : STD_LOGIC_VECTOR(10 DOWNTO 0);
	SIGNAL PC_SAVED     : STD_LOGIC_VECTOR(10 DOWNTO 0);
	SIGNAL MEM_ADDR     : STD_LOGIC_VECTOR(10 DOWNTO 0);
	SIGNAL MW           : STD_LOGIC;
	SIGNAL IO_WRITE_INT : STD_LOGIC;
	SIGNAL GIE          : STD_LOGIC;
	SIGNAL IIE      : STD_LOGIC_VECTOR( 3 DOWNTO 0);
	SIGNAL INT_REQ      : STD_LOGIC_VECTOR( 3 DOWNTO 0);
	SIGNAL INT_REQ_SYNC : STD_LOGIC_VECTOR( 3 DOWNTO 0); -- registered version of INT_REQ
	SIGNAL INT_ACK      : STD_LOGIC_VECTOR( 3 DOWNTO 0);


BEGIN
	-- Use altsyncram component for unified program and data memory
	MEMORY : altsyncram
	GENERIC MAP (
		intended_device_family => "Cyclone",
		width_a          => 16,
		widthad_a        => 11,
		numwords_a       => 2048,
		operation_mode   => "SINGLE_PORT",
		outdata_reg_a    => "UNREGISTERED",
		indata_aclr_a    => "NONE",
		wrcontrol_aclr_a => "NONE",
		address_aclr_a   => "NONE",
		outdata_aclr_a   => "NONE",
		init_file        => "SimpleRobotDemo.mif",
		lpm_hint         => "ENABLE_RUNTIME_MOD=NO",
		lpm_type         => "altsyncram"
	)
	PORT MAP (
		wren_a    => MW,
		clock0    => NOT(CLOCK),
		address_a => MEM_ADDR,
		data_a    => AC,
		q_a       => MDR
	);

	-- Use LPM function to shift AC using the SHIFT instruction
	SHIFTER: LPM_CLSHIFT
	GENERIC MAP (
		lpm_width     => 16,
		lpm_widthdist => 4,
		lpm_shifttype => "ARITHMETIC"
	)
	PORT MAP (
		data      => AC,
		distance  => IR(3 DOWNTO 0),
		direction => IR(4),
		result    => AC_SHIFTED
	);

	-- Use LPM function to drive I/O bus
	IO_BUS: LPM_BUSTRI
	GENERIC MAP (
		lpm_width => 16
	)
	PORT MAP (
		data     => AC,
		enabledt => IO_WRITE_INT,
		tridata  => IO_DATA
	);


	IO_ADDR  <= IR(7 DOWNTO 0);

	WITH STATE SELECT MEM_ADDR <=
		PC WHEN FETCH,
		IR(10 DOWNTO 0) WHEN OTHERS;

	IO_WRITE <= IO_WRITE_INT;

	PROCESS (CLOCK, RESETN)
	BEGIN
		IF (RESETN = '0') THEN          -- Active low, asynchronous reset
			STATE <= RESET_PC;
		ELSIF (RISING_EDGE(CLOCK)) THEN
			CASE STATE IS
				WHEN RESET_PC =>
					MW        <= '0';          -- Clear memory write flag
					PC        <= "00000000000"; -- Reset PC to the beginning of memory, address 0x000
					AC        <= x"0000";      -- Clear AC register
					IO_WRITE_INT <= '0';
					GIE       <= '1';          -- Enable interrupts
					IIE       <= "0000";       -- Mask all interrupts
					STATE     <= FETCH;
					INT_REQ_SYNC <= "0000";

				WHEN FETCH =>
					MW    <= '0';       -- Clear memory write flag
					IR    <= MDR;       -- Latch instruction into the IR
					IO_WRITE_INT <= '0';       -- Lower IO_WRITE after an OUT
					-- Interrupt Control
					IF (GIE = '1') AND  -- If Global Interrupt Enable set and...
					  (INT_REQ_SYNC /= "0000") THEN -- ...an interrupt is pending
						IF INT_REQ_SYNC(0) = '1' THEN   -- Got interrupt on PCINT0
							INT_ACK <= "0001";     -- Acknowledge the interrupt
							PC <= "00000000001";    -- Redirect execution
						ELSIF INT_REQ_SYNC(1) = '1' THEN
							INT_ACK <= "0010";     -- repeat for other pins
							PC <= "00000000010";
						ELSIF INT_REQ_SYNC(2) = '1' THEN
							INT_ACK <= "0100";
							PC <= "00000000011";
						ELSIF INT_REQ_SYNC(3) = '1' THEN
							INT_ACK <= "1000";
							PC <= "00000000100";
						END IF;
						GIE <= '0';            -- Disable interrupts while in ISR
						AC_SAVED <= AC;        -- Save AC
						PC_SAVED <= PC;        -- Save PC
						STATE <= FETCH;        -- Repeat FETCH with new PC
					ELSE -- either no interrupt or interrupts disabled
						PC        <= PC + 1;   -- Increment PC to next instruction address
						STATE     <= DECODE;
						INT_ACK   <= "0000";   -- Clear any interrupt acknowledge
					END IF;

				WHEN DECODE =>
					CASE IR(15 downto 11) IS
						WHEN "00000" =>       -- No Operation (NOP)
							STATE <= FETCH;
						WHEN "00001" =>       -- LOAD
							STATE <= EX_LOAD;
						WHEN "00010" =>       -- STORE
							STATE <= EX_STORE;
						WHEN "00011" =>       -- ADD
							STATE <= EX_ADD;
						WHEN "00100" =>       -- SUB
							STATE <= EX_SUB;
						WHEN "00101" =>       -- JUMP
							STATE <= EX_JUMP;
						WHEN "00110" =>       -- JNEG
							STATE <= EX_JNEG;
						WHEN "00111" =>       -- JPOS
							STATE <= EX_JPOS;
						WHEN "01000" =>       -- JZERO
							STATE <= EX_JZERO;
						WHEN "01001" =>       -- AND
							STATE <= EX_AND;
						WHEN "01010" =>       -- OR
							STATE <= EX_OR;
						WHEN "01011" =>       -- XOR
							STATE <= EX_XOR;
						WHEN "01100" =>       -- SHIFT
							STATE <= EX_SHIFT;
						WHEN "01101" =>       -- ADDI
							STATE <= EX_ADDI;
						WHEN "01110" =>       -- ILOAD
							STATE <= EX_ILOAD;
						WHEN "01111" =>       -- ISTORE
							STATE <= EX_ISTORE;
						WHEN "10000" =>       -- CALL
							STATE <= EX_CALL;
						WHEN "10001" =>       -- RETURN
							STATE <= EX_RETURN;
						WHEN "10010" =>       -- IN
							IO_CYCLE <= '1';
							STATE <= EX_IN;
						WHEN "10011" =>       -- OUT
							STATE <= EX_OUT;
							IO_WRITE_INT <= '1'; -- raise IO_WRITE
						WHEN "10100" =>       -- CLI
							IIE <= IIE AND NOT(IR(3 DOWNTO 0));  -- disable indicated interrupts
							STATE <= FETCH;
						WHEN "10101" =>       -- SEI
							IIE <= IIE OR IR(3 DOWNTO 0);  -- enable indicated interrupts
							STATE <= FETCH;
						WHEN "10110" =>       -- RETI
							STATE <= EX_RETI;
						WHEN "10111" =>       -- LOADI
							STATE <= EX_LOADI;

						WHEN OTHERS =>
							STATE <= FETCH;      -- Invalid opcodes default to NOP
					END CASE;

				WHEN EX_LOAD =>
					AC    <= MDR;            -- Latch data from MDR (memory contents) to AC
					STATE <= FETCH;

				WHEN EX_STORE =>
					MW    <= '1';            -- Raise MW to write AC to MEM
					STATE <= EX_STORE2;

				WHEN EX_STORE2 =>
					MW    <= '0';            -- Drop MW to end write cycle
					STATE <= FETCH;

				WHEN EX_ADD =>
					AC    <= AC + MDR;
					STATE <= FETCH;

				WHEN EX_SUB =>
					AC    <= AC - MDR;
					STATE <= FETCH;

				WHEN EX_JUMP =>
					PC    <= IR(10 DOWNTO 0);
					STATE <= FETCH;

				WHEN EX_JNEG =>
					IF (AC(15) = '1') THEN
						PC    <= IR(10 DOWNTO 0);
					END IF;

				STATE <= FETCH;

				WHEN EX_JPOS =>
					IF ((AC(15) = '0') AND (AC /= x"0000")) THEN
						PC    <= IR(10 DOWNTO 0);
					END IF;
					STATE <= FETCH;

				WHEN EX_JZERO =>
					IF (AC = x"0000") THEN
						PC    <= IR(10 DOWNTO 0);
					END IF;
					STATE <= FETCH;

				WHEN EX_AND =>
					AC    <= AC AND MDR;
					STATE <= FETCH;

				WHEN EX_OR =>
					AC    <= AC OR MDR;
					STATE <= FETCH;

				WHEN EX_XOR =>
					AC    <= AC XOR MDR;
					STATE <= FETCH;
                                      
				WHEN EX_SHIFT =>
					AC    <= AC_SHIFTED;
					STATE <= FETCH;

				WHEN EX_ADDI =>
					AC    <= AC + (IR(10) & IR(10) & IR(10) &
					 IR(10) & IR(10) & IR(10 DOWNTO 0));
					STATE <= FETCH;

				WHEN EX_ILOAD =>
					IR(10 DOWNTO 0) <= MDR(10 DOWNTO 0);
					STATE <= EX_LOAD;

				WHEN EX_ISTORE =>
					IR(10 DOWNTO 0) <= MDR(10 DOWNTO 0);
					STATE          <= EX_STORE;

				WHEN EX_CALL =>
					FOR i IN 0 TO 8 LOOP
						PC_STACK(i + 1) <= PC_STACK(i);
					END LOOP;
					PC_STACK(0) <= PC;
					PC          <= IR(10 DOWNTO 0);
					STATE       <= FETCH;

				WHEN EX_RETURN =>
					FOR i IN 0 TO 8 LOOP
						PC_STACK(i) <= PC_STACK(i + 1);
					END LOOP;
					PC          <= PC_STACK(0);
					STATE       <= FETCH;

				WHEN EX_IN =>
					AC <= IO_DATA;
					STATE <= EX_IN2;

				WHEN EX_IN2 =>
					IO_CYCLE <= '0';
					STATE <= FETCH;

				WHEN EX_OUT =>
					IO_CYCLE <= '1';
					STATE <= EX_OUT2;

				WHEN EX_OUT2 =>
					IO_CYCLE <= '0';
					STATE <= FETCH;

				WHEN EX_LOADI =>
					AC    <= (IR(10) & IR(10) & IR(10) &
					 IR(10) & IR(10) & IR(10 DOWNTO 0));
					STATE <= FETCH;

				WHEN EX_RETI =>
					GIE   <= '1';      -- re-enable interrupts
					PC    <= PC_SAVED; -- restore saved registers
					AC    <= AC_SAVED;
					STATE <= FETCH;

				WHEN OTHERS =>
					STATE <= FETCH;          -- If an invalid state is reached, return to FETCH
					
			END CASE;
			INT_REQ_SYNC <= INT_REQ;  -- register interrupt requests to SCOMP's clock.
		END IF;
	END PROCESS;
	
	-- This process monitors the external interrupt pins, setting
	-- some flags if a rising edge is detected, and clearing flags
	-- once the interrupt is acknowledged.
	PROCESS(RESETN, PCINT, INT_ACK, IIE)
	BEGIN
		IF (RESETN = '0') THEN
			INT_REQ <= "0000";  -- clear all interrupts on reset
		ELSE
			FOR i IN 0 TO 3 LOOP -- for each of the 4 interrupt pins
				IF (INT_ACK(i) = '1') OR (IIE(i) = '0') THEN
					INT_REQ(i) <= '0';   -- if acknowledged or masked, clear interrupt
				ELSIF RISING_EDGE(PCINT(i)) THEN
					INT_REQ(i) <= '1';   -- if rising edge on PCINT, request interrupt
				END IF;
			END LOOP;
		END IF;
	END PROCESS;

END a;
