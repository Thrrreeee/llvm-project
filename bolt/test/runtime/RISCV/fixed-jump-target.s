## Marine's ignored AES function uses c.j to a separate error helper.
## Neither compressed nor regular fixed jumps may clobber live temporaries.
# REQUIRES: system-linux
# RUN: llvm-mc -triple=riscv64 -mattr=+c -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs %t.o -o %t.exe
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --skip-funcs=fixed --reorder-functions=cdsort -o %t.bolt
# RUN: %t.bolt
# RUN: llvm-nm -n %t.exe > %t.syms
# RUN: llvm-nm -n %t.bolt >> %t.syms
# RUN: FileCheck %s --check-prefix=SYMS < %t.syms
# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.regular.o
# RUN: ld.lld --emit-relocs %t.regular.o -o %t.regular.exe
# RUN: llvm-bolt %t.regular.exe --skip-funcs=fixed --reorder-functions=cdsort -o %t.regular.bolt
# RUN: %t.regular.bolt

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
  j .Ltarget
  .size fixed, .-fixed

  .globl target
  .type target,@function
target:
.Ltarget:
  mv a0, t0
  ret
  .size target, .-target
