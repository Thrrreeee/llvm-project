# REQUIRES: system-linux,bolt-runtime

## An invalid secondary entry makes retained unrewritable. Scanning its
## PCREL_HI20 expression used to assert in extractFixupExpr. Keep the address
## materialization valid and still instrument the independently movable f.
# RUN: %clang %cflags -Wl,-q -o %t.exe %s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --instrumentation-file=%t.fdata -o %t.instr
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --input-file=%t.fdata
# CHECK: f 0 0 1{{$}}
# RUN: llvm-bolt %t.exe --data=%t.fdata --reorder-blocks=cache -o %t.bolt
# RUN: %t.bolt

  .option norelax
  .option norvc
  .text
  .globl main
  .type main,@function
main:
  addi sp, sp, -16
  sd ra, 0(sp)
  call retained
  lla t1, target
  bne a0, t1, .Lfail
  call f
  j .Lreturn
.Lfail:
  li a0, 1
.Lreturn:
  ld ra, 0(sp)
  addi sp, sp, 16
  ret
  .size main, .-main

  .globl retained
  .type retained,@function
retained:
.Lhi:
  auipc a0, %pcrel_hi(target)
  addi a0, a0, %pcrel_lo(.Lhi)
  ret
  .size retained, .-retained

  .globl target
  .type target,@function
target:
  ret
  .size target, .-target

  .globl f
  .type f,@function
f:
  li a0, 0
  ret
  .size f, .-f

  .data
  .globl invalid_entry_ref
invalid_entry_ref:
  .quad retained+2

  .section .note.GNU-stack,"",@progbits
