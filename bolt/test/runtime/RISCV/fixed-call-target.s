## Preserve the target of a fixed JAL, but update an existing AUIPC/JALR pair
## in place when its target moves. Neither path may clobber a live temporary.
# REQUIRES: system-linux
# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs %t.o -o %t.exe
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --skip-funcs=fixed --reorder-functions=cdsort -o %t.bolt
# RUN: %t.bolt
# RUN: llvm-nm -n %t.exe > %t.syms
# RUN: llvm-nm -n %t.bolt >> %t.syms
# RUN: FileCheck %s --check-prefix=SYMS < %t.syms
# RUN: llvm-mc -triple=riscv64 -filetype=obj --defsym LONG_CALL=1 %s -o %t.long.o
# RUN: ld.lld --no-relax --emit-relocs %t.long.o -o %t.long.exe
# RUN: llvm-bolt %t.long.exe --skip-funcs=fixed --reorder-functions=cdsort -o %t.long.bolt
# RUN: %t.long.bolt
# RUN: llvm-nm -n %t.long.exe > %t.long.syms
# RUN: llvm-nm -n %t.long.bolt >> %t.long.syms
# RUN: FileCheck %s --check-prefix=LONG-SYMS < %t.long.syms
# RUN: llvm-mc -triple=riscv64 -filetype=obj --defsym LONG_CALL=1 \
# RUN:   --defsym NO_RELOC=1 %s -o %t.no-reloc.o
# RUN: ld.lld --no-relax --emit-relocs %t.no-reloc.o -o %t.no-reloc.exe
# RUN: llvm-bolt %t.no-reloc.exe --skip-funcs=fixed -o %t.no-reloc.bolt
# RUN: %t.no-reloc.bolt
# RUN: llvm-nm -n %t.no-reloc.exe > %t.no-reloc.syms
# RUN: llvm-nm -n %t.no-reloc.bolt >> %t.no-reloc.syms
# RUN: FileCheck %s --check-prefix=LONG-SYMS < %t.no-reloc.syms

# SYMS: [[FIXED:[0-9a-f]+]] T fixed
# SYMS: [[TARGET:[0-9a-f]+]] T target
# SYMS: [[FIXED]] T fixed
# SYMS: [[TARGET]] T target
# LONG-SYMS: [[FIXED:[0-9a-f]+]] T fixed
# LONG-SYMS: 000000000001{{[0-9a-f]+}} T target
# LONG-SYMS: [[FIXED]] T fixed
# LONG-SYMS: 000000000040{{[0-9a-f]+}} T target

  .text
  .globl _start
  .type _start,@function
_start:
  li t0, 42
  call fixed
  addi a0, a0, -42
  li a7, 93
  ecall
  .size _start, .-_start

  .globl fixed
  .type fixed,@function
fixed:
  addi sp, sp, -16
  sd ra, 0(sp)
  .ifdef LONG_CALL
  .ifdef NO_RELOC
  # The linker may resolve a pair within a section without leaving a CALL
  # relocation. The target is 20 bytes after this AUIPC.
  auipc ra, 0
  jalr ra, 20(ra)
  .else
  call target
  .endif
  .else
  jal target
  .endif
  ld ra, 0(sp)
  addi sp, sp, 16
  ret
  .size fixed, .-fixed

  .globl target
  .type target,@function
target:
  mv a0, t0
  ret
  .size target, .-target
