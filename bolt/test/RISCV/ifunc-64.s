## Check that BOLT recognizes RISC-V non-preemptible IFUNC IPLT entries.

# RUN: llvm-mc -filetype=obj -triple=riscv64 -mattr=+relax -o %t.o %s
# RUN: ld.lld -pie -q -o %t.exe %t.o
# RUN: llvm-bolt %t.exe -o %t.bolt --print-disasm --print-only=_start 2>&1 \
# RUN:   | FileCheck --check-prefix=BOLT %s
# RUN: llvm-readelf -r -s %t.bolt | FileCheck --check-prefix=CHECK %s

# BOLT: Binary Function "_start
# BOLT: auipc ra, resolver@PLT
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
