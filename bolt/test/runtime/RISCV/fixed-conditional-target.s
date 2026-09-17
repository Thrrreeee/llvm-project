## Marine's ignored OpenSSL CBC function branches to a separate local helper.
## Keep that helper reachable without clobbering live temporary registers.
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
  li t1, 16
  li a2, 0
  call fixed
  addi a0, a0, -42
  li a7, 93
  ecall
  .size _start, .-_start

  .globl fixed
  .type fixed,@function
fixed:
  blt a2, t1, .Ltarget
  ret
  .size fixed, .-fixed

  .globl target
  .type target,@function
target:
.Ltarget:
  mv a0, t0
  ret
  .size target, .-target
