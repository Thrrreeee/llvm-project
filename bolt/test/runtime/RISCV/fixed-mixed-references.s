## Scanning a fixed source must finish before recursively preserving short
## branch targets. Otherwise their scans replace the shared symbolizer and a
## later AUIPC/JALR call can be missed. Its callee may also be folded by ICF.

# REQUIRES: system-linux
# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --no-relax --emit-relocs %t.o -o %t
# RUN: %t
# RUN: llvm-bolt %t --skip-funcs=fixed -o %t.bolt
# RUN: %t.bolt
# RUN: llvm-nm %t > %t.syms
# RUN: llvm-nm %t.bolt >> %t.syms
# RUN: FileCheck %s --check-prefix=PINNED < %t.syms
# RUN: llvm-nm %t.bolt | FileCheck %s --check-prefix=MOVED
# RUN: llvm-bolt %t --skip-funcs=fixed --icf=all -o %t.icf.bolt
# RUN: %t.icf.bolt
# RUN: llvm-nm %t.icf.bolt | FileCheck %s --check-prefix=ICF

# PINNED: [[FIXED:[0-9a-f]+]] T fixed
# PINNED: [[BRANCH1:[0-9a-f]+]] T target_branch1
# PINNED: [[BRANCH2:[0-9a-f]+]] T target_branch2
# PINNED: [[CHAIN1:[0-9a-f]+]] T target_chain1
# PINNED: [[CHAIN2:[0-9a-f]+]] T target_chain2
# PINNED: [[FIXED]] T fixed
# PINNED: [[BRANCH1]] T target_branch1
# PINNED: [[BRANCH2]] T target_branch2
# PINNED: [[CHAIN1]] T target_chain1
# PINNED: [[CHAIN2]] T target_chain2
# MOVED: 000000000040{{[0-9a-f]+}} T target_call
# ICF: [[CALL:000000000040[0-9a-f]+]] T target_call
# ICF: [[CALL]] T target_identical

  .text
  .option norvc
  .option norelax
  .globl _start
  .type _start,@function
_start:
  li t0, 42
  li a0, 1
  call fixed
  addi a0, a0, -42
  li a7, 93
  ecall
  .size _start, .-_start

  .globl fixed
  .type fixed,@function
fixed:
  addi sp, sp, -16
  sd ra, 0(sp)
  beqz a0, target_branch1
  beqz a0, target_branch2
  call target_call
  ld ra, 0(sp)
  addi sp, sp, 16
  ret
  .size fixed, .-fixed

  .globl target_branch1
  .type target_branch1,@function
target_branch1:
  j target_chain1
  .size target_branch1, .-target_branch1

  .globl target_branch2
  .type target_branch2,@function
target_branch2:
  j target_chain2
  .size target_branch2, .-target_branch2

  .globl target_chain1
  .type target_chain1,@function
target_chain1:
  li a0, 1
  ret
  .size target_chain1, .-target_chain1

  .globl target_chain2
  .type target_chain2,@function
target_chain2:
  li a0, 2
  ret
  .size target_chain2, .-target_chain2

  .globl target_call
  .type target_call,@function
target_call:
  mv a0, t0
  ret
  .size target_call, .-target_call

  .globl target_identical
  .type target_identical,@function
target_identical:
  mv a0, t0
  ret
  .size target_identical, .-target_identical
