// Check that BOLT preserves original RISC-V instruction bits while applying
// relocated control-flow immediates in the output binary.

// RUN: llvm-mc -triple riscv64 -mattr=+c -filetype=obj -o %t.o %s
// RUN: ld.lld --emit-relocs -o %t %t.o
// RUN: llvm-bolt -o %t.bolt --lite=0 %t
// RUN: llvm-objdump -d --no-show-raw-insn %t.bolt | FileCheck %s

  .text
  .globl _start
  .p2align 1
_start:
  jal ra, f
  beqz a0, g
  c.j h
  c.beqz a1, g
  ret
  .size _start, .-_start

  .globl f
  .p2align 1
f:
  ret
  .size f, .-f

  .globl g
  .p2align 1
g:
  ret
  .size g, .-g

  .globl h
  .p2align 1
h:
  ret
  .size h, .-h

// CHECK-LABEL: Disassembly of section .text:
// CHECK-LABEL: <_start>:
// CHECK-NEXT:  jal 0x{{[0-9a-f]+}} <f>
// CHECK-NEXT:  bnez a0, 0x{{[0-9a-f]+}} <_start+0x8>
// CHECK-NEXT:  j 0x{{[0-9a-f]+}} <g>
// CHECK-NEXT:  j 0x{{[0-9a-f]+}} <h>
