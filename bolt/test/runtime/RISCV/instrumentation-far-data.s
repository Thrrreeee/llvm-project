# REQUIRES: system-linux,bolt-runtime

## Dynamic relocation of the prefix slots must survive counter MAP_FIXED setup.
## Exercise original high bases with multiple lows, stores, and a cross-BB use.
# RUN: %clang %cflags -pie -Wl,-q -o %t.exe %s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --instrumentation-file=%t.fdata -o %t.instr
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: llvm-bolt %t.exe --data=%t.fdata --reorder-blocks=cache -o %t.bolt
# RUN: %t.bolt

# PROFILE: exercise 0 0 1{{$}}

  .text
  .globl main
  .type main,@function
main:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  call exercise
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .globl exercise
  .type exercise,@function
exercise:
  .cfi_startproc
  .option push
  .option norelax
.Lread:
  auipc t2, %pcrel_hi(value)
  ld t3, %pcrel_lo(.Lread)(t2)
  addi t4, t2, %pcrel_lo(.Lread)
  ld t5, 0(t4)
  bne t3, t5, .Lbad
  addi t6, t2, 17
  sub t6, t6, t2
  li a0, 17
  bne t6, a0, .Lbad
  li a0, 0
  bnez a0, .Lcross
  nop
.Lcross:
  lw t5, %pcrel_lo(.Lread)(t2)
  bne t3, t5, .Lbad
.Lwrite:
  auipc t2, %pcrel_hi(result)
  sd t3, %pcrel_lo(.Lwrite)(t2)
  ld t4, %pcrel_lo(.Lwrite)(t2)
  bne t3, t4, .Lbad
.Lgot:
  auipc t2, %got_pcrel_hi(value)
  ld t4, %pcrel_lo(.Lgot)(t2)
  ld t4, 0(t4)
  bne t3, t4, .Lbad
  li a0, 0
  ret
.Lbad:
  li a0, 1
  ret
  .option pop
  .cfi_endproc
  .size exercise, .-exercise

  .section .rodata,"a",@progbits
  .p2align 3
  .type value,@object
value:
  .quad 37
  .size value, .-value

  .data
  .p2align 3
  .type result,@object
result:
  .quad 0
  .size result, .-result
  .quad value

  .section .note.GNU-stack,"",@progbits
