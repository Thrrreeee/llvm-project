# REQUIRES: system-linux,bolt-runtime

## An ignored internal-call function can share a jump table with a fragment
## that is still emitted. The original data relocations must preserve its hot
## entry and redirect its cold entry to the emitted fragment and callee.
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.plain.exe %s
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -Wa,-defsym,INTERNAL_CALL=1 \
# RUN:   -o %t.internal.exe %s
# RUN: %t.plain.exe
# RUN: %t.internal.exe
# RUN: llvm-bolt %t.plain.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --funcs=main,dispatch,dispatch.cold.1,body_callee -v=3 \
# RUN:   --instrumentation-file=%t.plain.fdata -o %t.plain.instr \
# RUN:   2>&1 | FileCheck %s --check-prefixes=SHARED,PLAIN
# RUN: llvm-bolt %t.internal.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --funcs=main,dispatch,dispatch.cold.1,body_callee -v=3 \
# RUN:   --instrumentation-file=%t.internal.fdata -o %t.internal.instr \
# RUN:   2>&1 | FileCheck %s --check-prefixes=SHARED,INTERNAL
# RUN: %python %S/Inputs/shared-jt-original-check.py %t.plain.exe %t.plain.instr \
# RUN:   %t.internal.exe %t.internal.instr
# RUN: rm -f %t.plain.fdata %t.internal.fdata
# RUN: %t.plain.instr
# RUN: %t.internal.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.plain.fdata
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.internal.fdata

# SHARED: multiple fragments access the same jump table: dispatch; dispatch.cold.1
# PLAIN-NOT: preserving original code for
# INTERNAL: internal call detected in function dispatch
# INTERNAL: preserving original code for 1 RISC-V functions with internal calls
# PROFILE-COUNT-2: 1 main {{[0-9a-f]+}} 1 dispatch 0 0 1{{$}}
# PROFILE: body_callee 0 0 1{{$}}

  .option norelax
  .option norvc
  .text
  .globl main
  .type main,@function
main:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  li a0, 0
  call dispatch
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 1
  call dispatch
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 0
  j .Lreturn
.Lfail:
  li a0, 1
.Lreturn:
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .globl dispatch
  .type dispatch,@function
dispatch:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  .ifdef INTERNAL_CALL
  jal ra, .Linternal
  .endif
.Lfirst_hi:
  auipc a4, %pcrel_hi(PIC_JT)
  addi a4, a4, %pcrel_lo(.Lfirst_hi)
  slli a2, a0, 2
  add a2, a2, a4
  lw a2, 0(a2)
  add a2, a2, a4
  jr a2
.Lhotcase:
  li a0, 42
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
.Linternal:
  .cfi_def_cfa_offset 16
  .cfi_offset ra, -8
  ret
  .cfi_endproc
  .size dispatch, .-dispatch

  .quad 0
  .globl dispatch.cold.1
  .type dispatch.cold.1,@function
dispatch.cold.1:
  .cfi_startproc
  .cfi_def_cfa_offset 16
  .cfi_offset ra, -8
  nop
.Lsecond_hi:
  auipc a4, %pcrel_hi(PIC_JT)
  addi a4, a4, %pcrel_lo(.Lsecond_hi)
  slli a2, a0, 2
  add a2, a2, a4
  lw a2, 0(a2)
  add a2, a2, a4
  jr a2
.Lcoldcase:
  call body_callee
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size dispatch.cold.1, .-dispatch.cold.1

  .globl body_callee
  .type body_callee,@function
body_callee:
  .cfi_startproc
  li a0, 42
  ret
  .cfi_endproc
  .size body_callee, .-body_callee

  .section .rodata,"a",@progbits
  .p2align 3
  .globl PIC_JT
  .hidden PIC_JT
  .type PIC_JT,@object
PIC_JT:
  .word .Lhotcase - PIC_JT
  .word .Lcoldcase - PIC_JT
  .size PIC_JT, .-PIC_JT

  .data
  .p2align 3
  .quad PIC_JT
  .section .note.GNU-stack,"",@progbits
