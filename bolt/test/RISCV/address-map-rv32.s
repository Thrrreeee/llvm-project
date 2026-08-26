## Check that target addresses in BOLT's intermediary address map use the RV32
## code-pointer width, while label keys remain 64-bit host pointers.

# RUN: llvm-mc -filetype=obj -triple=riscv32 -mattr=+relax -o %t.o %s
# RUN: ld.lld -q -o %t %t.o
# RUN: rm -rf %t.tmp && mkdir %t.tmp
# RUN: env TMPDIR=%t.tmp llvm-bolt %t -o %t.bolt --use-old-text=0 --lite=0 \
# RUN:   --update-debug-sections --keep-tmp
# RUN: llvm-readelf -SW %t.tmp/output-*.o | FileCheck %s

## Three basic-block labels, each encoded as two 8-byte host values.
# CHECK: .bolt.label2addr_map PROGBITS {{.*}} 000030
## Three instruction addresses, each encoded as two 4-byte target values.
# CHECK: .bolt.addr2addr_map PROGBITS {{.*}} 000018

  .text
  .globl _start
  .type _start, @function
_start:
  beqz a0, .Lret
  ret
.Lret:
  ret
  .size _start, .-_start
