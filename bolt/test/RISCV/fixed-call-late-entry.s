## Rejecting a fixed CALL pair can make its callee fixed after interprocedural
## entries have been registered. Keep checking calls discovered by those later
## scans: a second shared JALR must preserve its callee, while the independent
## call in that callee must still be relocated when its target moves.
## Resolve this before ICF can fold that callee with an otherwise movable alias.

# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --no-relax --emit-relocs %t.o -o %t
# RUN: llvm-bolt %t --skip-funcs=fixed -o %t.bolt
# RUN: llvm-nm %t > %t.syms
# RUN: llvm-nm %t.bolt >> %t.syms
# RUN: FileCheck %s --check-prefix=PINNED < %t.syms
# RUN: llvm-nm %t.bolt | FileCheck %s --check-prefix=MOVED
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.bolt | FileCheck %s
# RUN: llvm-bolt %t --skip-funcs=fixed --icf=all -o %t.icf.bolt
# RUN: llvm-nm %t > %t.icf.syms
# RUN: llvm-nm %t.icf.bolt >> %t.icf.syms
# RUN: FileCheck %s --check-prefix=PINNED < %t.icf.syms
# RUN: llvm-nm %t.icf.bolt | FileCheck %s --check-prefix=MOVED
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.icf.bolt | FileCheck %s

# PINNED: [[FIXED:[0-9a-f]+]] T fixed
# PINNED: [[FIRST:[0-9a-f]+]] T target_first
# PINNED: [[SECOND:[0-9a-f]+]] T target_second
# PINNED: [[FIXED]] T fixed
# PINNED: [[FIRST]] T target_first
# PINNED: [[SECOND]] T target_second
# MOVED: {{^0*40[0-9a-f]+}} T target_movable
# MOVED: {{^0*40[0-9a-f]+}} T target_second_alias

# CHECK-LABEL: <target_second>:
# CHECK-NEXT: auipc t1,
# CHECK-NEXT: jalr zero, {{.*}}(t1) <target_movable>

  .text
  .option norvc
  .option norelax
  .globl _start
  .type _start,@function
_start:
  j .Lfixed_entry
  .size _start, .-_start

  .globl enter_first
  .type enter_first,@function
enter_first:
  j .Lfirst_entry
  .size enter_first, .-enter_first

  .globl fixed
  .type fixed,@function
fixed:
  .reloc ., R_RISCV_CALL_PLT, target_first
  auipc t1, 0
.Lfixed_entry:
  jalr zero, 0(t1)
  .size fixed, .-fixed

  .globl target_first
  .type target_first,@function
target_first:
  .reloc ., R_RISCV_CALL_PLT, target_second
  auipc t1, 0
.Lfirst_entry:
  jalr zero, 0(t1)
  .size target_first, .-target_first

  .globl target_second
  .type target_second,@function
target_second:
  tail target_movable
  .size target_second, .-target_second

  .globl target_second_alias
  .type target_second_alias,@function
target_second_alias:
  tail target_movable
  .size target_second_alias, .-target_second_alias

  .globl target_movable
  .type target_movable,@function
target_movable:
  li a0, 42
  ret
  .size target_movable, .-target_movable
