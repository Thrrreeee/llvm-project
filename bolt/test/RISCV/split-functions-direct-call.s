## Check that RISC-V split-function branch relaxation ignores direct calls.
## FixRISCVCallsPass represents them with PseudoCALL/PseudoTAIL, which emit
## AUIPC/JALR pairs and do not have a short branch encoding size.

# RUN: llvm-mc -triple riscv64 -mattr=+c -filetype=obj -o %t.o %s
# RUN: ld.lld --emit-relocs -e _start -o %t.exe %t.o
# RUN: llvm-bolt %t.exe -o %t.bolt -split-functions \
# RUN:   -split-strategy=random2 -bolt-seed=1
# RUN: llvm-objdump -d --no-show-raw-insn %t.bolt | FileCheck %s

# CHECK-LABEL: <_start>:
# CHECK:       {{(auipc|jal)}}
# CHECK-LABEL: <callee>:

  .text
  .globl _start
  .type _start, @function
_start:
  beqz a0, .Lcold
  call callee
  li a0, 1
  ret
.Lcold:
  li a0, 2
  ret
  .size _start, .-_start

  .globl callee
  .type callee, @function
callee:
  ret
  .size callee, .-callee

  .reloc 0, R_RISCV_NONE
