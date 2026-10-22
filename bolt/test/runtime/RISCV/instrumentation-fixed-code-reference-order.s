# REQUIRES: system-linux,bolt-runtime

## Taking a preserved function's address also requires PC-relative placement.
## Keep aliases, secondary entries and original low operands intact. A target
## that becomes fixed only during entry patching must constrain its address user.
# RUN: split-file %s %t.dir
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.exe %t.dir/input.s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --instrument-calls \
# RUN:   --riscv-instrumentation-far-data \
# RUN:   --print-fix-riscv-calls --print-only=negative_user \
# RUN:   --funcs=main,high_user,negative_user,tie_user,padding,low_user,secondary_user,late_user,tiny,atomic \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.fdata \
# RUN:   -o %t.instr 2>&1 | FileCheck %s
# RUN: llvm-bolt %t.exe --instrument --instrument-calls \
# RUN:   --funcs=main,high_user,negative_user,tie_user,padding,low_user,secondary_user,late_user,tiny,atomic \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.off.fdata \
# RUN:   -o %t.off 2>&1 | FileCheck %s --check-prefix=OFF
# RUN: llvm-bolt %t.exe --instrument --instrument-calls --force-patch \
# RUN:   --riscv-instrumentation-far-data \
# RUN:   --funcs=main,high_user,negative_user,tie_user,padding,low_user,secondary_user,late_user,tiny,atomic \
# RUN:   --function-order=%t.dir/user.order --instrumentation-file=%t.late.fdata \
# RUN:   -o %t.late 2>&1 | FileCheck %s --check-prefix=LATE
# RUN: %python %S/Inputs/fixed-code-reference-order-check.py %t.exe %t.instr %t.off %t.late
# RUN: rm -f %t.fdata %t.off.fdata %t.late.fdata
# RUN: %t.instr
# RUN: %t.off
# RUN: %t.late
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.off.fdata
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.late.fdata

# CHECK: auipc a0, %pcrel_hi(fixed_high-12)
# CHECK: kept 1 LR/SC functions
# CHECK: RISC-V far-data placement: 1 functions placed before remaining emitted functions
# CHECK: RISC-V fixed-code placement: 5 functions ordered by PC-relative deadlines
# OFF-NOT: RISC-V fixed-code placement
# LATE: failed to patch entries in tiny
# LATE: RISC-V fixed-code placement: 8 functions ordered by PC-relative deadlines
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 high_user 0 0 1{{$}}
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 negative_user 0 0 1{{$}}
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 tie_user 0 0 1{{$}}
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 low_user 0 0 1{{$}}
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 secondary_user 0 0 1{{$}}
# PROFILE-DAG: 1 main {{[0-9a-f]+}} 1 late_user 0 0 1{{$}}

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
  c.li a0, 21
  c.jr ra
  .option pop
  .cfi_endproc
  .size tiny, .-tiny
  ## The next function leaves exactly four bytes available for tiny's patch.
  .globl fixed_low
  .type fixed_low,@function
fixed_low:
  .cfi_startproc
  li a0, 20
  .globl fixed_low_secondary
  .hidden fixed_low_secondary
fixed_low_secondary:
  addi a0, a0, 1
  ret
  .cfi_endproc
  .size fixed_low, .-fixed_low
  .globl fixed_low_alias
  .type fixed_low_alias,@function
  .set fixed_low_alias, fixed_low
  .size fixed_low_alias, .-fixed_low

  .globl fixed_high
  .type fixed_high,@function
fixed_high:
  .cfi_startproc
  li a0, 21
  ret
  .cfi_endproc
  .size fixed_high, .-fixed_high
  ## Entry-patch forward deadlines must follow these fixed-reference limits.
  .zero 8192

  .macro address_user name, target
  .globl \name
  .type \name,@function
\name:
  .cfi_startproc
.Lhigh\@:
  auipc a0, %pcrel_hi(\target)
  addi a0, a0, %pcrel_lo(.Lhigh\@)
  ret
  .cfi_endproc
  .size \name, .-\name
  .endm
  address_user high_user, fixed_high
  ## This crosses a function boundary so relocation processing retains the
  ## negative addend instead of canonicalizing an internal entry to +0.
  address_user negative_user, fixed_high-12
  address_user tie_user, fixed_low_alias
  address_user low_user, fixed_low
  address_user secondary_user, fixed_low+4
  address_user late_user, tiny

  .globl padding
  .type padding,@function
padding:
  .cfi_startproc
  .rept 16
  addi t0, t0, 1
  .endr
  ret
  .cfi_endproc
  .size padding, .-padding

  .globl atomic
  .type atomic,@function
atomic:
  .cfi_startproc
  lr.d a1, (a0)
  sc.d a2, a1, (a0)
  ret
  .cfi_endproc
  .size atomic, .-atomic

  .option rvc
  .globl main
  .type main,@function
main:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  sd s0, 0(sp)
  .cfi_offset s0, -16
  li s0, 0
  .macro run_user name
  call \name
  mv t0, a0
  li a0, 20
  jalr ra, t0, 0
  add s0, s0, a0
  .endm
  run_user high_user
  run_user negative_user
  run_user tie_user
  run_user low_user
  run_user secondary_user
  run_user late_user
  addi a0, s0, -126
  ld s0, 0(sp)
  .cfi_restore s0
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .data
  .p2align 3
data:
  .quad data
  .section .note.GNU-stack,"",@progbits

#--- user.order
main
high_user
tie_user
padding
low_user
secondary_user
negative_user
late_user
tiny
atomic
