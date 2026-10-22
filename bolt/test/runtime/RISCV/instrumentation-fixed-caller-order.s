# REQUIRES: system-linux,bolt-runtime

## Callers of fixed code follow the functions already constrained by data
## references, and precede ordinary functions. Earlier fixed targets constrain
## their callers first; equal targets retain their relative user order.
# RUN: split-file %s %t.dir
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.exe %t.dir/input.s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --instrument-calls \
# RUN:   --riscv-instrumentation-far-data \
# RUN:   --funcs=main,atomic,padding,direct_caller,tail_caller,low_caller \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.fdata \
# RUN:   -o %t.instr 2>&1 | FileCheck %s
# RUN: llvm-bolt %t.exe --instrument --instrument-calls \
# RUN:   --funcs=main,atomic,padding,direct_caller,tail_caller,low_caller \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.off.fdata \
# RUN:   -o %t.off 2>&1 | FileCheck %s --check-prefix=OFF
# RUN: %python %S/Inputs/fixed-caller-order-check.py %t.exe %t.instr %t.off
# RUN: rm -f %t.fdata %t.off.fdata
# RUN: %t.instr
# RUN: %t.off
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.off.fdata

# CHECK: kept 1 LR/SC functions
# CHECK: RISC-V far-data placement
# CHECK: RISC-V fixed-code placement: 3 functions ordered by PC-relative deadlines
# CHECK: RISC-V far-data placement changes the requested function order
# OFF-NOT: RISC-V far-data placement
# PROFILE-DAG: 1 direct_caller {{[0-9a-f]+}} 1 fixed_leaf 0 0 1{{$}}
# PROFILE-DAG: 1 tail_caller {{[0-9a-f]+}} 1 fixed_leaf 0 0 1{{$}}
# PROFILE-DAG: 1 low_caller {{[0-9a-f]+}} 1 fixed_low 0 0 1{{$}}

#--- input.s
  .option norelax
  .option norvc
  .text
  .globl fixed_low
  .type fixed_low,@function
fixed_low:
  .cfi_startproc
  li a0, 21
  ret
  .cfi_endproc
  .size fixed_low, .-fixed_low

  .globl main
  .type main,@function
main:
  .cfi_startproc
  addi sp, sp, -32
  .cfi_def_cfa_offset 32
  sd ra, 24(sp)
  .cfi_offset ra, -8
  sd s0, 16(sp)
  .cfi_offset s0, -16
  call direct_caller
  mv s0, a0
  call tail_caller
  add s0, a0, s0
  call low_caller
  add a0, a0, s0
  addi a0, a0, -63
  ld s0, 16(sp)
  .cfi_restore s0
  ld ra, 24(sp)
  .cfi_restore ra
  addi sp, sp, 32
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .globl direct_caller
  .type direct_caller,@function
direct_caller:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  call fixed_leaf
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size direct_caller, .-direct_caller

  .globl tail_caller
  .type tail_caller,@function
tail_caller:
  .cfi_startproc
  tail fixed_leaf
  .cfi_endproc
  .size tail_caller, .-tail_caller

  .globl low_caller
  .type low_caller,@function
low_caller:
  .cfi_startproc
  tail fixed_low
  .cfi_endproc
  .size low_caller, .-low_caller

  .globl atomic
  .type atomic,@function
atomic:
  .cfi_startproc
  lr.d a1, (a0)
  sc.d a2, a1, (a0)
  ret
  .cfi_endproc
  .size atomic, .-atomic

  .globl padding
  .type padding,@function
padding:
  .cfi_startproc
  ## Keep this ordinary function below the entry-patching threshold.
  .rept 16
  addi t0, t0, 1
  .endr
  ret
  .cfi_endproc
  .size padding, .-padding

  .globl fixed_leaf
  .type fixed_leaf,@function
fixed_leaf:
  .cfi_startproc
  li a0, 21
  ret
  .cfi_endproc
  .size fixed_leaf, .-fixed_leaf

  .data
  .p2align 3
data:
  .quad data
  .section .note.GNU-stack,"",@progbits

#--- user.order
padding
direct_caller
main
tail_caller
low_caller
atomic
