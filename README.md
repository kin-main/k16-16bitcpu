# k16-16bitcpu 
# fpga RISC CPU Architecture Specification
> **Note:** This document is a compiled and translated version of the author's personal notes, structured with AI assistance.
> 
## 1. System Overview & Design Goals
 * **Core Concept**: A discrete RISC CPU constructed using standard 74HC-series logic ICs. Designed to maximize operational clock frequency by keeping the architecture simple.
 * **Pipeline**: 2-stage pipeline (Stage 1: Fetch / Decode, Stage 2: Execute / Register Access / ALU / Load-Store).
 * **Data & Instruction Width**: **16-bit** data width for registers and ALU operations. **24-bit** fixed instruction word length (1 word = 24 bits).
 * **Address Space**: **16-bit** address space (64 KB capacity).
## 2. Register File Architecture
The CPU features 16 general-purpose and special-purpose registers (r0 through r15):
| Register | Name | Description & Behavior |
|---|---|---|
| r0 | Zero Register | Hardwired to constant 0. Write operations are discarded. |
| r1 – r12 | General Purpose (GPR) | General-purpose 16-bit registers for arithmetic and data manipulation. |
| r13 | Upper Byte / Extension | Acts as the high-order data byte register (bits 16–24) during Load/Store (LD/ST) operations. |
| r14 | Flags Register | Holds ALU condition flags (Z: Zero, C: Carry, N: Negative). Writes are ignored. |
| r15 | Program Counter (PC) | Holds the address of the current instruction to be executed. |
## 3. Instruction Format Definitions
All instructions are fixed 24-bit words. The top 3 bits (cond) specify conditional execution for every instruction.
### 1) Register-Register Instruction Format (op = 00)
cond(3) + op(2) + rd(4) + rs1(4) + rs(4) + Unused(4) + funkt(3) = 24-bit
### 2) Register-Immediate Instruction Format (op = 01)
cond(3) + op(2) + rd(4) + rs(4) + im(8) + funkt(3) = 24-bit
### 3) Load / Store Instruction Format (op = 11)
cond(3) + op(2) + rd(4) + base(4) + im(9) + funkt(2) = 24-bit
## 4. Execution Conditions & Opcodes
### Condition Fields (cond[23:21])
 * 000: Always execute
 * 001: Z == 0
 * 010: C == 0
 * 011: N == 0
 * 100: Never (NOP)
 * 101: Z == 1
 * 110: C == 1
 * 111: N == 1
### ALU Operations (funkt[2:0] for op=00 / op=01)
 * 000: NAND
 * 001: OR
 * 010: AND
 * 011: XOR
 * 100: ADD
 * 101: SUB
 * 110: ADC
 * 111: SHR
### Load / Store Operations (funkt[1:0] for op=11)
 * 00: Load (Add Immed: base + im)
 * 01: Load (Sub Immed: base - im)
 * 10: Store (Add Immed: base + im)
 * 11: Store (Sub Immed: base - im)
## 5. Pipeline & Datapath Microarchitecture
### Pipeline Stages
 * **Stage 1 (Fetch & Decode)**: Instruction Fetch from Memory, Instruction Register (IR) latching, Primary Decoding & Control Line Generation.
 * **Stage 2 (Execute & Access)**: Register File Read / Write, Condition Evaluation via Sub-Decoder, ALU Execution & Flag Update (Z, C, N), Memory Load / Store Data Transfer.
