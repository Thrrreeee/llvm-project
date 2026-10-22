# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## Without C/Zca, zero/one/two dead scratches require 40/32/16 bytes.
## A one-register spill always reserves 16 bytes, never an 8-byte frame.
# RUN: llvm-mc -triple=riscv64 -mattr=+a -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=two --fini=none %t.o -o %t
# RUN: llvm-bolt %t --instrument -o %t.instr
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.instr | FileCheck %s
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+zca -defsym=WITH_ZCA=1 -filetype=obj %s -o %t.zca.o
# RUN: ld.lld --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=two --fini=none %t.zca.o -o %t.zca
# RUN: llvm-bolt %t.zca --instrument -o %t.zca.instr
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.zca.instr | FileCheck %s --check-prefix=ZCA

# CHECK-LABEL: <two>:
# CHECK-NEXT: [[#%x,TWO:]]: auipc a0,
# CHECK-NEXT: [[#TWO+4]]: addi a0, a0,
# CHECK-NEXT: [[#TWO+8]]: addi a1, zero, 0x1
# CHECK-NEXT: [[#TWO+12]]: amoadd.d zero, a1, (a0)
# CHECK-NEXT: [[#TWO+16]]: addi a0, zero, 0x15
# CHECK-LABEL: <one>:
# CHECK-NEXT: [[#%x,ONE:]]: addi sp, sp, -0x10
# CHECK-NEXT: [[#ONE+4]]: sd a0, 0x0(sp)
# CHECK-NEXT: [[#ONE+8]]: auipc a1,
# CHECK-NEXT: [[#ONE+12]]: addi a1, a1,
# CHECK-NEXT: [[#ONE+16]]: addi a0, zero, 0x1
# CHECK-NEXT: [[#ONE+20]]: amoadd.d zero, a0, (a1)
# CHECK-NEXT: [[#ONE+24]]: ld a0, 0x0(sp)
# CHECK-NEXT: [[#ONE+28]]: addi sp, sp, 0x10
# CHECK-NEXT: [[#ONE+32]]: addi a1, zero, 0x7
# CHECK-LABEL: <none>:
# CHECK-NEXT: [[#%x,NONE:]]: addi sp, sp, -0x10
# CHECK-NEXT: [[#NONE+4]]: sd a0, 0x0(sp)
# CHECK-NEXT: [[#NONE+8]]: sd a1, 0x8(sp)
# CHECK: [[#NONE+40]]: add a0, a0, a1

# ZCA-LABEL: <two>:
# ZCA-NEXT: [[#%x,TWO:]]: auipc a0,
# ZCA-NEXT: [[#TWO+4]]: addi a0, a0,
# ZCA-NEXT: [[#TWO+8]]: c.li a1, 0x1
# ZCA-NEXT: [[#TWO+10]]: amoadd.d zero, a1, (a0)
# ZCA-NEXT: [[#TWO+14]]: addi a0, zero, 0x15
# ZCA-LABEL: <one>:
# ZCA-NEXT: [[#%x,ONE:]]: c.addi sp, -0x10
# ZCA-NEXT: [[#ONE+2]]: c.sdsp a0, 0x0(sp)
# ZCA-NEXT: [[#ONE+4]]: auipc a1,
# ZCA: [[#ONE+20]]: c.addi sp, 0x10
# ZCA-NEXT: [[#ONE+22]]: addi a1, zero, 0x7

  .ifdef WITH_ZCA
  .attribute arch, "rv64ia_zca"
  .else
  .attribute arch, "rv64ia"
  .endif
  .option norvc
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  call two
  call one
  call none
  li a0, 0
  li a7, 93
  ecall
  .size _start, .-_start

  .globl two
  .type two,@function
two:
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  .size two, .-two

  .globl one
  .type one,@function
one:
  li a1, 7
  add a0, a0, a1
  ret
  .size one, .-one

  .globl none
  .type none,@function
none:
  add a0, a0, a1
  ret
  .size none, .-none
