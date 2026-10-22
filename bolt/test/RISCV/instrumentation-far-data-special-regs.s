# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## The slot address must never become a temporary SP, GP, or TP value.
## Keep these entire functions on direct PC-relative references, even when
## another ordinary register reference in the same function could use a slot.
# RUN: llvm-mc -triple=riscv64 -mattr=+a -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs --no-relax -pie -e _start --dynamic-linker=ld.so \
# RUN:   --init=finish --fini=finish %t.o -o %t
# RUN: llvm-bolt %t --instrument --riscv-instrumentation-far-data \
# RUN:   -o %t.instr 2>&1 | FileCheck %s --check-prefix=LOG
# RUN: llvm-objdump --disassemble-symbols=use_sp,use_gp,use_tp %t.instr \
# RUN:   | FileCheck %s

# LOG: RISC-V far-data slots replaced 0 AUIPC references and restored 0 low operands
# LOG-SAME: 3 functions with unverified references for early placement
# LOG: RISC-V far-data placement: 3 functions placed before remaining emitted functions
# CHECK-LABEL: <use_sp>:
# CHECK: auipc sp,
# CHECK-NEXT: addi a0, sp,
# CHECK-LABEL: <use_gp>:
# CHECK: auipc gp,
# CHECK-NEXT: addi a0, gp,
# CHECK-LABEL: <use_tp>:
# CHECK: auipc tp,
# CHECK-NEXT: addi a0, tp,

  .attribute arch, "rv64ia"
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  call finish
  li a0, 0
  li a7, 93
  ecall
  .size _start, .-_start

  .macro special name, reg
  .globl \name
  .type \name,@function
\name:
  mv t0, \reg
.Lordinary\@:
  auipc t1, %pcrel_hi(value)
  addi a1, t1, %pcrel_lo(.Lordinary\@)
.Lspecial\@:
  auipc \reg, %pcrel_hi(value)
  addi a0, \reg, %pcrel_lo(.Lspecial\@)
  mv \reg, t0
  ret
  .size \name, .-\name
  .endm

  special use_sp, sp
  special use_gp, gp
  special use_tp, tp

  .globl finish
  .type finish,@function
finish:
  ret
  .size finish, .-finish

  .data
  .p2align 3
value:
  .quad value
