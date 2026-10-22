# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## A freestanding binary avoids inheriting C from the host's C runtime. The
## counter is 40 bytes without C/Zca and 26 bytes with either extension. Both
## variants must retain a full-width AUIPC/ADDI PCREL pair with a valid anchor.
# RUN: llvm-mc -triple=riscv64 -mattr=+a -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=f --fini=f %t.o -o %t
# RUN: llvm-bolt %t --instrument -o %t.instr
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases --disassemble-symbols=f %t.instr \
# RUN:   | FileCheck %s --check-prefix=FULL
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+c -defsym=WITH_C=1 -filetype=obj %s -o %t.c.o
# RUN: ld.lld --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=f --fini=f %t.c.o -o %t.c
# RUN: llvm-bolt %t.c --instrument -o %t.c.instr
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases --disassemble-symbols=f %t.c.instr \
# RUN:   | FileCheck %s --check-prefix=COMPRESSED
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+zca -defsym=WITH_ZCA=1 -filetype=obj %s -o %t.zca.o
# RUN: ld.lld --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=f --fini=f %t.zca.o -o %t.zca
# RUN: llvm-bolt %t.zca --instrument -o %t.zca.instr
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases --disassemble-symbols=f %t.zca.instr \
# RUN:   | FileCheck %s --check-prefix=COMPRESSED

# FULL-LABEL: <f>:
# FULL-NEXT: [[#%x,START:]]: addi sp, sp, -0x10
# FULL-NEXT: [[#START+4]]: sd a0, 0x0(sp)
# FULL-NEXT: [[#START+8]]: sd a1, 0x8(sp)
# FULL-NEXT: [[#START+12]]: auipc a0,
# FULL-NEXT: [[#START+16]]: addi a0, a0,
# FULL-NEXT: [[#START+20]]: addi a1, zero, 0x1
# FULL-NEXT: [[#START+24]]: amoadd.d zero, a1, (a0)
# FULL-NEXT: [[#START+28]]: ld a0, 0x0(sp)
# FULL-NEXT: [[#START+32]]: ld a1, 0x8(sp)
# FULL-NEXT: [[#START+36]]: addi sp, sp, 0x10
# FULL-NEXT: [[#START+40]]: jalr zero, 0x0(ra)

# COMPRESSED-LABEL: <f>:
# COMPRESSED-NEXT: [[#%x,START:]]: c.addi sp, -0x10
# COMPRESSED-NEXT: [[#START+2]]: c.sdsp a0, 0x0(sp)
# COMPRESSED-NEXT: [[#START+4]]: c.sdsp a1, 0x8(sp)
# COMPRESSED-NEXT: [[#START+6]]: auipc a0,
# COMPRESSED-NEXT: [[#START+10]]: addi a0, a0,
# COMPRESSED-NEXT: [[#START+14]]: c.li a1, 0x1
# COMPRESSED-NEXT: [[#START+16]]: amoadd.d zero, a1, (a0)
# COMPRESSED-NEXT: [[#START+20]]: c.ldsp a0, 0x0(sp)
# COMPRESSED-NEXT: [[#START+22]]: c.ldsp a1, 0x8(sp)
# COMPRESSED-NEXT: [[#START+24]]: c.addi sp, 0x10
# COMPRESSED-NEXT: [[#START+26]]: {{(c.jr ra|jalr zero, 0x0\(ra\))}}

  .ifdef WITH_C
  .attribute arch, "rv64iac"
  .else
  .ifdef WITH_ZCA
  .attribute arch, "rv64ia_zca"
  .else
  .attribute arch, "rv64ia"
  .endif
  .endif

  .text
  .globl _start
  .type _start,@function
_start:
  call f
  li a0, 0
  li a7, 93
  ecall
  .size _start, .-_start

  .globl f
  .type f,@function
f:
  ret
  .size f, .-f
