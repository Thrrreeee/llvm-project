## Estimate the emitted PseudoTAIL entry patch as an eight-byte AUIPC/JALR pair.
## The instruction after the patch must remain at its original address.

# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs %t.o -o %t.exe
# RUN: llvm-bolt %t.exe --force-patch -o %t.bolt 2>&1 | FileCheck %s
# RUN: llvm-objdump -d --section=.bolt.org.text %t.bolt | FileCheck %s --check-prefix=PATCH

# CHECK: BOLT-INFO: enabling relocation mode
# CHECK-NOT: could not find corresponding %pcrel_hi
# PATCH-LABEL: <_start.org.0>:
# PATCH-NEXT: [[#%x,ADDR:]]: {{.*}} auipc t1,
# PATCH-NEXT: [[#ADDR+4]]: {{.*}} jr {{.*}}(t1) <_start>
# PATCH-NEXT: [[#ADDR+8]]: {{.*}} ecall

  .text
  .globl _start
  .type _start,@function
_start:
  li a0, 0
  li a7, 93
  ecall
  .reloc 0, R_RISCV_NONE
  .size _start, .-_start
