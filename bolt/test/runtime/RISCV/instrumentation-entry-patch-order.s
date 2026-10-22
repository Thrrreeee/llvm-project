# REQUIRES: system-linux,bolt-runtime

## Original entry patches impose forward CALL bounds, while callers of fixed
## code impose backward bounds. Merge these bounds without changing the first
## group. A late patchability failure must also constrain its remaining callers.
# RUN: split-file %s %t.dir
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.exe %t.dir/input.s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --instrument-calls --force-patch \
# RUN:   --riscv-instrumentation-far-data \
# RUN:   --funcs=main,entry_early,padding,entry_late,late_caller,back_caller,tiny,atomic_first,atomic_second \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.fdata \
# RUN:   -o %t.instr 2>&1 | FileCheck %s
# RUN: llvm-bolt %t.exe --instrument --instrument-calls --force-patch \
# RUN:   --funcs=main,entry_early,padding,entry_late,late_caller,back_caller,tiny,atomic_first,atomic_second \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.off.fdata \
# RUN:   -o %t.off 2>&1 | FileCheck %s --check-prefix=OFF
# RUN: %python %S/Inputs/entry-patch-order-check.py %t.exe %t.instr %t.off
# RUN: rm -f %t.fdata %t.off.fdata
# RUN: %t.instr
# RUN: %t.off
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.off.fdata

# CHECK: kept 2 LR/SC functions
# CHECK: failed to patch entries in tiny
# CHECK: RISC-V far-data placement: 2 functions placed before remaining emitted functions
# CHECK: RISC-V fixed-call placement: 6 functions ordered by call-range deadlines
# CHECK: RISC-V far-data placement changes the requested function order
# OFF: failed to patch entries in tiny
# OFF-NOT: RISC-V fixed-call placement
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 {{entry_early|entry_alias}} 0 0 1{{$}}
# PROFILE-DAG: 0 [unknown] 0 1 {{entry_early|entry_alias}} 8 0 1{{$}}
# PROFILE-DAG: 1 late_caller {{[0-9a-f]+}} 1 tiny 0 0 1{{$}}
# PROFILE-DAG: 1 back_caller {{[0-9a-f]+}} 1 fixed_leaf 0 0 1{{$}}

#--- input.s
  .option norelax
  .option norvc
  .text
  .globl tiny
  .type tiny,@function
tiny:
  .cfi_startproc
  .option push
  .option rvc
  c.li a0, 7
  c.jr ra
  .option pop
  .cfi_endproc
  .size tiny, .-tiny
  ## No alignment or padding: tiny has only four bytes available for a patch.
  .globl fixed_leaf
  .type fixed_leaf,@function
fixed_leaf:
  .cfi_startproc
  li a0, 21
  ret
  .cfi_endproc
  .size fixed_leaf, .-fixed_leaf
  ## Put fixed_leaf's backward deadline strictly between entry_early's
  ## primary and secondary forward deadlines. This catches overwriting the
  ## tighter primary constraint with the later secondary constraint.
  .zero 4086

  .globl entry_early
  .type entry_early,@function
entry_early:
  .cfi_startproc
  li a0, 20
  ret
  .globl secondary_entry
  .hidden secondary_entry
secondary_entry:
  li a0, 22
  ret
  .cfi_endproc
  .size entry_early, .-entry_early
  .globl entry_alias
  .type entry_alias,@function
  .set entry_alias, entry_early
  .size entry_alias, .-entry_early

  .globl padding
  .type padding,@function
padding:
  .cfi_startproc
  .rept 2048
  addi t0, t0, 1
  .endr
  ret
  .cfi_endproc
  .size padding, .-padding

  .globl entry_late
  .type entry_late,@function
entry_late:
  .cfi_startproc
  li a0, 1
  ret
  .cfi_endproc
  .size entry_late, .-entry_late

  .globl late_caller
  .type late_caller,@function
late_caller:
  .cfi_startproc
  tail tiny
  .cfi_endproc
  .size late_caller, .-late_caller

  .globl back_caller
  .type back_caller,@function
back_caller:
  .cfi_startproc
  tail fixed_leaf
  .cfi_endproc
  .size back_caller, .-back_caller

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
  call entry_alias
  mv s0, a0
  call secondary_entry
  add s0, s0, a0
  call late_caller
  add s0, s0, a0
  call back_caller
  add s0, s0, a0
  call entry_late
  add a0, s0, a0
  addi a0, a0, -71
  ld s0, 16(sp)
  .cfi_restore s0
  ld ra, 24(sp)
  .cfi_restore ra
  addi sp, sp, 32
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .globl atomic_first
  .type atomic_first,@function
atomic_first:
  .cfi_startproc
  lr.d a1, (a0)
  sc.d a2, a1, (a0)
  ret
  .cfi_endproc
  .size atomic_first, .-atomic_first

  .globl atomic_second
  .type atomic_second,@function
atomic_second:
  .cfi_startproc
  lr.d a2, (a0)
  sc.d a1, a2, (a0)
  ret
  .cfi_endproc
  .size atomic_second, .-atomic_second

  .data
  .p2align 3
data:
  .quad data
  .section .note.GNU-stack,"",@progbits

#--- user.order
main
entry_late
back_caller
late_caller
padding
entry_early
tiny
atomic_second
atomic_first
