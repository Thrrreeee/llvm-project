## Only a complete, independently rewritable CALL pair can move its target.
## Preserve targets for mismatched registers, entries at the JALR, ordinary
## HI/LO address materialization, invalid targets, and failed disassembly.

# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --no-relax --emit-relocs %t.o -o %t
# RUN: llvm-bolt %t --skip-funcs='fixed_.*' -o %t.bolt
# RUN: llvm-nm %t > %t.syms
# RUN: llvm-nm %t.bolt >> %t.syms
# RUN: FileCheck %s --check-prefix=SYMS < %t.syms

# SYMS: [[ADDRESS:[0-9a-f]+]] T target_address
# SYMS: [[BADBASE:[0-9a-f]+]] T target_bad_base
# SYMS: [[ENTRY:[0-9a-f]+]] T target_entry
# SYMS: [[AFTER:[0-9a-f]+]] T target_internal_after
# SYMS: [[BEFORE:[0-9a-f]+]] T target_internal_before
# SYMS: [[ISLAND:[0-9a-f]+]] T target_island
# SYMS: [[TRUNCATED:[0-9a-f]+]] T target_truncated
# SYMS: [[ADDRESS]] T target_address
# SYMS: [[BADBASE]] T target_bad_base
# SYMS: [[ENTRY]] T target_entry
# SYMS: [[AFTER]] T target_internal_after
# SYMS: [[BEFORE]] T target_internal_before
# SYMS: [[ISLAND]] T target_island
# SYMS: [[TRUNCATED]] T target_truncated

  .text
  .option norvc
  .option norelax
  .globl _start
  .type _start,@function
_start:
  # The JALR has another incoming edge, so changing it independently of that
  # edge's register state is unsafe.
  j .Lentry
  .size _start, .-_start

  .globl fixed_bad_base
  .type fixed_bad_base,@function
fixed_bad_base:
  .reloc ., R_RISCV_CALL_PLT, target_bad_base
  auipc ra, 0
  jalr ra, 0(t1)
  ret
  .size fixed_bad_base, .-fixed_bad_base

  .globl fixed_entry
  .type fixed_entry,@function
fixed_entry:
  .reloc ., R_RISCV_CALL_PLT, target_entry
  auipc t1, 0
.Lentry:
  jalr ra, 0(t1)
  ret
  .size fixed_entry, .-fixed_entry

  .globl fixed_internal_before
  .type fixed_internal_before,@function
fixed_internal_before:
  bnez a0, .Lbefore
  .reloc ., R_RISCV_CALL_PLT, target_internal_before
  auipc t1, 0
.Lbefore:
  jalr ra, 0(t1)
  ret
  .size fixed_internal_before, .-fixed_internal_before

  .globl fixed_internal_after
  .type fixed_internal_after,@function
fixed_internal_after:
  .reloc ., R_RISCV_CALL_PLT, target_internal_after
  auipc t1, 0
.Lafter:
  jalr ra, 0(t1)
  bnez a0, .Lafter
  ret
  .size fixed_internal_after, .-fixed_internal_after

  .globl fixed_address
  .type fixed_address,@function
fixed_address:
.Lhi:
  auipc a0, %pcrel_hi(target_address)
  addi a0, a0, %pcrel_lo(.Lhi)
  ret
  .size fixed_address, .-fixed_address

  .globl fixed_truncated
  .type fixed_truncated,@function
fixed_truncated:
  call target_truncated
  # Keep the code mapping symbol; a .word directive would mark this as data
  # and would not exercise a failure to disassemble the source.
  .insn 4, 0x0000007b
  .size fixed_truncated, .-fixed_truncated

  .globl fixed_island
  .type fixed_island,@function
fixed_island:
  # A resolved pair without a CALL relocation targets the data at
  # target_island+4, sixteen bytes after this AUIPC.
  auipc ra, 0
  jalr ra, 16(ra)
  ret
  .size fixed_island, .-fixed_island

  .globl target_island
  .type target_island,@function
target_island:
  ret
  .word 0
  ret
  .size target_island, .-target_island

  .globl target_address
  .type target_address,@function
target_address:
  li a0, 1
  ret
  .size target_address, .-target_address

  .globl target_bad_base
  .type target_bad_base,@function
target_bad_base:
  li a0, 2
  ret
  .size target_bad_base, .-target_bad_base

  .globl target_entry
  .type target_entry,@function
target_entry:
  li a0, 3
  ret
  .size target_entry, .-target_entry

  .globl target_internal_before
  .type target_internal_before,@function
target_internal_before:
  li a0, 5
  ret
  .size target_internal_before, .-target_internal_before

  .globl target_internal_after
  .type target_internal_after,@function
target_internal_after:
  li a0, 6
  ret
  .size target_internal_after, .-target_internal_after

  .globl target_truncated
  .type target_truncated,@function
target_truncated:
  li a0, 4
  ret
  .size target_truncated, .-target_truncated
