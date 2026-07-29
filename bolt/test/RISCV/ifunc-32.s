## Check that BOLT recognizes RISC-V non-preemptible IFUNC IPLT entries.

## RV32 static binaries use a 32-bit wordclass IRELATIVE field.
# RUN: llvm-mc -filetype=obj -triple=riscv32 -mattr=+relax -o %t.32.o %s
# RUN: ld.lld -q -o %t.32.exe %t.32.o
# RUN: llvm-bolt %t.32.exe -o %t.32.bolt
# RUN: llvm-readelf -r -s %t.32.bolt | FileCheck --check-prefix=CHECK %s

# CHECK: R_RISCV_IRELATIVE{{.*}}[[#%x,RESOLVER:]]
# CHECK: [[#RESOLVER]] {{.*}} FUNC {{.*}} resolver

  .text
  .globl _start
  .type _start, @function
_start:
  .option push
  .option norelax
  call ifunc0
  .option pop

  .globl resolver, ifunc0
  .type resolver, @function
  .type ifunc0, @gnu_indirect_function
resolver:
ifunc0:
  ret
  .size resolver, .-resolver
