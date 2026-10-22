## Discover absolute JALR entries before finalizing fixed CALL relocations.
## The four-byte _start is ignored only when entry patching fails, which is too
## late to discover that it enters fixed's JALR. The odd immediate must have its
## low bit cleared. Preserve target before ICF can fold it with target_alias.

# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.64.o
# RUN: ld.lld --no-relax --emit-relocs --image-base=0 -Ttext=0x100 %t.64.o -o %t.64
# RUN: llvm-bolt %t.64 --skip-funcs=fixed --force-patch -o %t.64.bolt 2>&1 | FileCheck %s --check-prefix=LATE
# RUN: llvm-nm %t.64 > %t.64.syms
# RUN: llvm-nm %t.64.bolt >> %t.64.syms
# RUN: FileCheck %s --check-prefix=PINNED < %t.64.syms
# RUN: llvm-nm %t.64.bolt | FileCheck %s --check-prefix=MOVED
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.64.bolt | FileCheck %s --check-prefixes=CHECK,POS
# RUN: llvm-bolt %t.64 --skip-funcs=fixed --force-patch --icf=all -o %t.icf.bolt
# RUN: llvm-nm %t.64 > %t.icf.syms
# RUN: llvm-nm %t.icf.bolt >> %t.icf.syms
# RUN: FileCheck %s --check-prefix=PINNED < %t.icf.syms
# RUN: llvm-nm %t.icf.bolt | FileCheck %s --check-prefix=MOVED
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.icf.bolt | FileCheck %s --check-prefixes=CHECK,POS
# RUN: llvm-mc -triple=riscv32 -defsym=RV32_NEGATIVE=1 -filetype=obj %s -o %t.32.o
# RUN: ld.lld --no-relax --emit-relocs --image-base=0xffff0000 -Ttext=0xfffff800 %t.32.o -o %t.32
# RUN: llvm-bolt %t.32 --skip-funcs=fixed --force-patch --no-huge-pages --use-gnu-stack \
# RUN:   --custom-allocation-vma=0xff000000 -o %t.32.bolt
# RUN: llvm-nm %t.32 > %t.32.syms
# RUN: llvm-nm %t.32.bolt >> %t.32.syms
# RUN: FileCheck %s --check-prefix=PINNED < %t.32.syms
# RUN: llvm-nm %t.32.bolt | FileCheck %s --check-prefix=NEG-MOVED
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.32.bolt | FileCheck %s --check-prefixes=CHECK,NEG

# LATE: failed to patch entries in _start
# PINNED: [[FIXED:[0-9a-f]+]] T fixed
# PINNED: [[TARGET:[0-9a-f]+]] T target
# PINNED: [[FIXED]] T fixed
# PINNED: [[TARGET]] T target
# MOVED: {{^0*40[0-9a-f]+}} T target_alias
# NEG-MOVED: {{^ff000[0-9a-f]+}} T target_alias
# CHECK-LABEL: <fixed>:
# CHECK-NEXT: auipc t1, 0x0
# CHECK-NEXT: jalr zero, 0xc(t1) <target>
# CHECK-LABEL: <_start>:
# POS-NEXT: jalr zero, 0x105(zero)
# NEG-NEXT: jalr zero, -0x7fb(zero)

  .text
  .option norvc
  .option norelax
  .globl fixed
  .type fixed,@function
fixed:
  tail target
  .size fixed, .-fixed

  .globl _start
  .type _start,@function
_start:
  .ifdef RV32_NEGATIVE
  jalr zero, -2043(zero)
  .else
  jalr zero, 0x105(zero)
  .endif
  .size _start, .-_start

  .globl target
  .type target,@function
target:
  li a0, 42
  .rept 12
  nop
  .endr
  ret
  .size target, .-target

  .globl target_alias
  .type target_alias,@function
target_alias:
  li a0, 42
  .rept 12
  nop
  .endr
  ret
  .size target_alias, .-target_alias

  ## An absolute target outside known functions must not enter the generic
  ## interprocedural reference queue, which expects mapped code addresses.
  .globl unmapped
  .type unmapped,@function
unmapped:
  jalr zero, 0x405(zero)
  .size unmapped, .-unmapped
