# REQUIRES: system-linux,bolt-runtime

## An internal call makes large non-simple. Its original jump fits within JAL
## range, but converting the fixed-data references before classifying the
## function would grow that jump beyond its last two bytes of headroom. Keep its
## instructions intact while still converting the ordinary reference in main.
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.exe %s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --funcs=main,large --instrumentation-file=%t.fdata \
# RUN:   -o %t.instr 2>&1 | FileCheck %s
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata

# CHECK: BOLT-WARNING: internal call detected in function large
# CHECK: RISC-V far-data slots replaced 1 AUIPC references and restored 1 low operands; kept 0 LR/SC functions, 1 non-simple functions
# CHECK: BOLT-INSTRUMENTER: Number of function descriptors: 1
# CHECK: RISC-V far-data placement: 1 functions placed before remaining emitted functions
# PROFILE-COUNT-2: 1 main {{[0-9a-f]+}} 1 large 0 0 1{{$}}

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
.Lmain_value:
  auipc t0, %pcrel_hi(value)
  ld t1, %pcrel_lo(.Lmain_value)(t0)
  li t2, 42
  bne t1, t2, .Lfail
  li a0, 0
  call large
  li t2, 42
  bne a0, t2, .Lfail
  li a0, 1
  call large
  li t2, 42
  bne a0, t2, .Lfail
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

  .globl large
  .type large,@function
large:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  bnez a0, .Lbody
  jal ra, .Linternal
  j .Lfar
.Linternal:
  li a0, 42
  ret
.Lbody:
.Llarge_value:
  auipc t0, %pcrel_hi(value)
  ld a0, %pcrel_lo(.Llarge_value)(t0)
  .rept 262138
  nop
  .endr
.Lfar:
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size large, .-large

  .section .rodata,"a",@progbits
  .p2align 3
  .type value,@object
value:
  .quad 42
  .size value, .-value

## Keep a dynamic RELATIVE relocation for the far-data mode.
  .data
  .p2align 3
  .quad value
  .section .note.GNU-stack,"",@progbits
