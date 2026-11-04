## An unused private code label needs no persistent BinaryData, but relocations,
## object/function identity, boundary labels, and data-in-code still matter.
# RUN: llvm-mc -triple=riscv64 -save-temp-labels -filetype=obj %s -o %t.o
# RUN: ld.lld --no-relax --emit-relocs %t.o -o %t
# RUN: llvm-nm -a %t | FileCheck %s --check-prefix=INPUT
# RUN: llvm-bolt %t --print-globals --print-aliases --keep-nops --enable-bat -o %t.bolt | FileCheck %s --check-prefix=GLOBALS --implicit-check-not=PG.Lunused/ --implicit-check-not=PG.Ldebug_only/
# RUN: llvm-nm -a --numeric-sort %t.bolt | FileCheck %s --check-prefix=OUTPUT
## The fixture exits through a syscall and can also be run natively in the
## runtime/RISCV suite, before and after rewriting.
# INPUT-DAG: .Lunused
# INPUT-DAG: .Ldebug_only
# INPUT-DAG: $d
# INPUT-DAG: $x
## BAT enables precise address translation. Even the two labels omitted from
## internal registration must survive in the output at their moved addresses.
# OUTPUT-DAG: [[#%x,START:]] t .Lboundary
# OUTPUT-DAG: [[#START+4]] t .Lunused
# OUTPUT-DAG: [[#START+8]] t .Ldebug_only
# OUTPUT-DAG: [[#START+12]] t .Lalloc_anchor
# OUTPUT-DAG: [[#START+20]] t .Lbranch_target
# OUTPUT-DAG: [[#START]] T _start
# OUTPUT-DAG: .Lobject
# OUTPUT-DAG: .Lfunction
# OUTPUT-DAG: .Lglobal
# OUTPUT-DAG: .Labsolute
# GLOBALS-DAG: PG.Lboundary/
# GLOBALS-DAG: PG.Lalloc_anchor/
# GLOBALS-DAG: PG.Lbranch_target/
# GLOBALS-DAG: PG.Lpool/
# GLOBALS-DAG: PG.Loutside/
# GLOBALS-DAG: PG.Lobject/
# GLOBALS-DAG: PG.Lfunction/
# GLOBALS-DAG: PG.Lglobal
# GLOBALS-DAG: PG.Labsolute/
# GLOBALS-DAG: PG.Lsized/
# GLOBALS-DAG: PG.Lsection_end/

  .text
  .option norvc
  .option norelax
  .globl _start
  .type _start,@function
_start:
.Lboundary:
  li a0, 0
.Lunused:
  nop
.Ldebug_only:
  nop
.Lalloc_anchor:
  auipc t0, %pcrel_hi(.Lobject)
  addi t0, t0, %pcrel_lo(.Lalloc_anchor)
.Lbranch_target:
  .reloc ., R_RISCV_BRANCH, .Lbranch_target
  bnez a0, .Lbranch_target
  .globl .Lglobal
.Lglobal:
  nop
.Lsized:
  nop
  .size .Lsized, .-.Lsized
  li a7, 93
  ecall
.Lpool:
  .dword 0
  .size _start, .-_start

## A zero-sized untyped assembly function outside _start must remain visible.
.Loutside:
  ret
  .type .Lfunction,@function
.Lfunction:
  ret
  .size .Lfunction, .-.Lfunction
.Lsection_end:

  .section .rodata,"a",@progbits
  .type .Lobject,@object
.Lobject:
  .dword 42
  .size .Lobject, .-.Lobject
  .set .Labsolute, 0x1234

## Debug-only references must not cause persistent symbol registration, while
## their original symbols and relocations remain in the unmodified input.
  .section .debug_labels,"",@progbits
  .dword .Ldebug_only
