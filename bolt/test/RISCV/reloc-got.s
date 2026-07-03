// RUN: %clang %cflags64 -o %t %s
// RUN: llvm-bolt --print-cfg --print-only=_start -o %t.null %t \
// RUN:    | FileCheck %s
// RUN: llvm-mc -triple riscv64 -mattr=+c -filetype=obj -o %t.o %s
// RUN: ld.lld --emit-relocs -o %t.mc %t.o
// RUN: llvm-bolt --print-cfg --print-only=_start -o %t.mc.null %t.mc \
// RUN:    | FileCheck %s --check-prefix=CHECK-MC

  .data
  .globl d
  .p2align 3
d:
  .dword 0

  .text
  .globl _start
  .p2align 1
// CHECK: Binary Function "_start" after building cfg {
_start:
  nop // Here to not make the _start and .Ltmp0 symbols coincide
// CHECK: auipc t0, %pcrel_hi(__BOLT_got_zero+{{[0-9]+}}) # Label: .Ltmp0
// CHECK-MC: auipc t0, %pcrel_hi(__BOLT_got_zero+74208) # Label: .Ltmp0
// CHECK-NEXT: ld t0, %pcrel_lo(.Ltmp0)(t0)
// CHECK-MC-NEXT: ld t0, %pcrel_lo(.Ltmp0)(t0)
1:
  auipc t0, %got_pcrel_hi(d)
  ld t0, %pcrel_lo(1b)(t0)
  ret
  .size _start, .-_start
