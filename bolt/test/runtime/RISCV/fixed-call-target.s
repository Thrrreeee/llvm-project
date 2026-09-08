## A relaxed JAL in marine's ignored DoAllocWithArena cannot be expanded in
## place. Preserve its callee, including live registers on non-ABI calls.
# REQUIRES: system-linux
# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs %t.o -o %t.exe
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --skip-funcs=fixed --reorder-functions=cdsort -o %t.bolt
# RUN: %t.bolt
# RUN: llvm-nm -n %t.exe > %t.syms
# RUN: llvm-nm -n %t.bolt >> %t.syms
# RUN: FileCheck %s --check-prefix=SYMS < %t.syms

# SYMS: [[FIXED:[0-9a-f]+]] T fixed
# SYMS: [[TARGET:[0-9a-f]+]] T target
# SYMS: [[FIXED]] T fixed
# SYMS: [[TARGET]] T target

  .text
  .globl _start
  .type _start,@function
_start:
  li t0, 42
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
  jal target
  ld ra, 0(sp)
  addi sp, sp, 16
  ret
  .size fixed, .-fixed

  .globl target
  .type target,@function
target:
  mv a0, t0
  ret
  .size target, .-target
