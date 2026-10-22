## Omitting a local label must not renumber a later typed function with the
## same spelling. Profile names depend on the original /N disambiguation.
# RUN: split-file %s %t
# RUN: llvm-mc -triple=riscv64 -save-temp-labels -filetype=obj %t/first.s -o %t/first.o
# RUN: llvm-mc -triple=riscv64 -save-temp-labels -filetype=obj %t/second.s -o %t/second.o
# RUN: ld.lld --no-relax --emit-relocs %t/first.o %t/second.o -o %t.exe
# RUN: llvm-bolt %t.exe --print-globals -o %t.bolt | FileCheck %s --implicit-check-not=PG.Lrepeat/1
# CHECK: PG.Lrepeat/2

#--- first.s
  .text
  .option norvc
  .globl _start
  .type _start,@function
_start:
  li a0, 0
.Lrepeat:
  li a7, 93
  ecall
  .size _start, .-_start

#--- second.s
  .text
  .option norvc
  .type .Lrepeat,@function
.Lrepeat:
  ret
  .size .Lrepeat, .-.Lrepeat
