# REQUIRES: system-linux,bolt-runtime

## Fixed AUIPC/JALR pairs in preserved code require their callees near the
## beginning of the new allocation. Cover both an alias and a secondary entry.
# RUN: split-file %s %t.dir
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.exe %t.dir/input.s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --funcs=main,preserved,padding,callee_primary,callee_secondary \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.fdata \
# RUN:   -o %t.instr 2>&1 | FileCheck %s
# RUN: llvm-bolt %t.exe --instrument \
# RUN:   --funcs=main,preserved,padding,callee_primary,callee_secondary \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.off.fdata \
# RUN:   -o %t.off 2>&1 | FileCheck %s --check-prefix=OFF
# RUN: %python %S/Inputs/fixed-call-order-check.py %t.exe %t.instr %t.off
# RUN: rm -f %t.fdata %t.off.fdata
# RUN: %t.instr
# RUN: %t.off
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.off.fdata

# CHECK: preserving original code for 1 RISC-V functions with internal calls
# CHECK: RISC-V far-data placement: 2 functions placed before remaining emitted functions
# CHECK: RISC-V far-data placement changes the requested function order
# OFF: preserving original code for 1 RISC-V functions with internal calls
# OFF-NOT: RISC-V far-data placement:
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 preserved 0 0 1{{$}}
# PROFILE-DAG: {{callee_primary|callee_alias}} 0 0 1{{$}}
# PROFILE-DAG: callee_secondary 8 0 1{{$}}

#--- input.s
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
  call preserved
  addi a0, a0, -42
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .globl preserved
  .type preserved,@function
preserved:
  .cfi_startproc
  addi sp, sp, -32
  .cfi_def_cfa_offset 32
  sd ra, 24(sp)
  .cfi_offset ra, -8
  sd s0, 16(sp)
  .cfi_offset s0, -16
  jal ra, .Linternal
  call callee_alias
  mv s0, a0
  call callee_secondary_entry
  add a0, a0, s0
  ld s0, 16(sp)
  .cfi_restore s0
  ld ra, 24(sp)
  .cfi_restore ra
  addi sp, sp, 32
  .cfi_def_cfa_offset 0
  ret
.Linternal:
  .cfi_def_cfa_offset 32
  .cfi_offset ra, -8
  .cfi_offset s0, -16
  ret
  .cfi_endproc
  .size preserved, .-preserved

  .globl padding
  .type padding,@function
padding:
  .cfi_startproc
  .rept 1024
  addi t0, t0, 1
  .endr
  ret
  .cfi_endproc
  .size padding, .-padding

  .globl callee_primary
  .type callee_primary,@function
callee_primary:
  .cfi_startproc
  li a0, 20
  ret
  .cfi_endproc
  .size callee_primary, .-callee_primary
  .globl callee_alias
  .type callee_alias,@function
  .set callee_alias, callee_primary
  .size callee_alias, .-callee_primary

  .globl callee_secondary
  .type callee_secondary,@function
callee_secondary:
  .cfi_startproc
  li a0, 0
  ret
  .globl callee_secondary_entry
  .hidden callee_secondary_entry
callee_secondary_entry:
  li a0, 22
  ret
  .cfi_endproc
  .size callee_secondary, .-callee_secondary

  .data
  .p2align 3
data:
  .quad data
  .section .note.GNU-stack,"",@progbits

#--- user.order
padding
main
callee_secondary
callee_primary
