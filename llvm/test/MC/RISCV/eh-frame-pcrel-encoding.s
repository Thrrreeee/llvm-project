# RUN: llvm-mc -triple riscv32 -filetype=obj %s -o %t.32.o
# RUN: llvm-readobj --relocations %t.32.o | FileCheck %s --implicit-check-not=R_RISCV_64
# RUN: llvm-mc -triple riscv64 -filetype=obj %s -o %t.64.o
# RUN: llvm-readobj --relocations %t.64.o | FileCheck %s --implicit-check-not=R_RISCV_64

## Both the CIE personality and the FDE LSDA pointer must use their requested
## PC-relative width. R_RISCV_32_PCREL cannot describe an eight-byte field.
# CHECK: .rela.eh_frame {
# CHECK: R_RISCV_32_PCREL personality32 0x0
# CHECK: R_RISCV_32_PCREL lsda32 0x0
# CHECK: [[PERSONALITY:0x[0-9A-F]+]] R_RISCV_ADD64 personality64 0x0
# CHECK-NEXT: [[PERSONALITY]] R_RISCV_SUB64 {{.*}} 0x0
# CHECK: [[LSDA:0x[0-9A-F]+]] R_RISCV_ADD64 lsda64 0x0
# CHECK-NEXT: [[LSDA]] R_RISCV_SUB64 {{.*}} 0x0

  .text
f32:
  .cfi_startproc
  .cfi_personality 0x9b, personality32
  .cfi_lsda 0x1b, lsda32
  nop
  .cfi_endproc

f64:
  .cfi_startproc
  .cfi_personality 0x9c, personality64
  .cfi_lsda 0x1c, lsda64
  nop
  .cfi_endproc
