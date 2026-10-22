## Fixed calls use the complete AUIPC/JALR pair. Updating the displacement must
## preserve both the base and link registers, including nonstandard pairs.
## Exercise both relocation types and both signs of the new displacement.

# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.64.o
# RUN: ld.lld --no-relax --emit-relocs -Ttext=0x21000 %t.64.o -o %t.64
# RUN: llvm-bolt %t.64 --skip-funcs=fixed -o %t.64.bolt
# RUN: llvm-nm %t.64.bolt | FileCheck %s --check-prefix=FORWARD
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.64.bolt | FileCheck %s
# RUN: llvm-bolt %t.64 --skip-funcs=fixed --no-huge-pages --use-gnu-stack \
# RUN:   --custom-allocation-vma=0x10000 -o %t.backward
# RUN: llvm-nm %t.backward | FileCheck %s --check-prefix=BACKWARD
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.backward | FileCheck %s
# RUN: not --crash llvm-bolt %t.64 --skip-funcs=fixed --no-huge-pages \
# RUN:   --use-gnu-stack --custom-allocation-vma=0x90000000 -o %t.far \
# RUN:   2>&1 | FileCheck %s --check-prefix=RANGE
# RUN: llvm-mc -triple=riscv32 -filetype=obj %s -o %t.32.o
# RUN: ld.lld --no-relax --emit-relocs -Ttext=0x21000 %t.32.o -o %t.32
# RUN: llvm-bolt %t.32 --skip-funcs=fixed -o %t.32.bolt
# RUN: llvm-nm %t.32.bolt | FileCheck %s --check-prefix=FORWARD
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.32.bolt | FileCheck %s

# FORWARD: {{^0*21000}} T fixed
# FORWARD: {{^0*40[0-9a-f]+}} T target_call
# FORWARD: {{^0*40[0-9a-f]+}} T target_call_plt
# FORWARD: {{^0*40[0-9a-f]+}} T target_tail
# BACKWARD: {{^0*21000}} T fixed
# BACKWARD: {{^0*1[0-9a-f]+}} T target_call
# BACKWARD: {{^0*1[0-9a-f]+}} T target_call_plt
# BACKWARD: {{^0*1[0-9a-f]+}} T target_tail
# RANGE: fixed RISC-V reference exceeds its encoding range

# CHECK-LABEL: <fixed>:
# CHECK-NEXT: addi a1, zero, 0x1
# CHECK-NEXT: auipc ra,
# CHECK-NEXT: jalr ra, {{.*}}(ra) <target_call>
# CHECK-NEXT: auipc t1,
# CHECK-NEXT: jalr t0, {{.*}}(t1) <target_call_plt>
# CHECK-NEXT: auipc t2,
# CHECK-NEXT: jalr zero, {{.*}}(t2) <target_tail>

  .text
  .option norvc
  .option norelax
  .globl fixed
  .type fixed,@function
fixed:
  # Offset the first pair so its low immediate is negative after rewriting.
  li a1, 1
  .reloc ., R_RISCV_CALL, target_call
  auipc ra, 0
  jalr ra, 0(ra)
  .reloc ., R_RISCV_CALL_PLT, target_call_plt
  auipc t1, 0
  jalr t0, 0(t1)
  .reloc ., R_RISCV_CALL_PLT, target_tail
  auipc t2, 0
  jalr zero, 0(t2)
  .size fixed, .-fixed

  .globl target_call
  .type target_call,@function
target_call:
  li a0, 1
  ret
  .size target_call, .-target_call

  .globl target_call_plt
  .type target_call_plt,@function
target_call_plt:
  li a0, 2
  jr t0
  .size target_call_plt, .-target_call_plt

  .globl target_tail
  .type target_tail,@function
target_tail:
  li a0, 3
  ret
  .size target_tail, .-target_tail

  .globl _start
  .type _start,@function
_start:
  ret
  .size _start, .-_start

  .section .note.GNU-stack,"",@progbits
