# REQUIRES: system-linux,bolt-runtime

## Check disjoint frame areas and personality/typeinfo slots more than 2 GiB
## away without a PLT call masking the EH problem. This is not executed.
# RUN: llvm-mc -triple=riscv64 -mattr=+a -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs --no-relax --eh-frame-hdr -pie -e _start \
# RUN:   --dynamic-linker=ld.so --init=fini --fini=fini \
# RUN:   --section-start=.text=0x10000 --section-start=.data=0x130800 %t.o -o %t.exe
# RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --skip-funcs=old_leaf --custom-allocation-vma=0x90000000 -o %t.instr
# RUN: %python %S/Inputs/far-data-unwind-check.py %t.exe %t.instr old_leaf new_leaf --far --exception-targets
# RUN: not llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --skip-funcs=old_leaf --custom-allocation-vma=0x120000000 -o %t.impossible \
# RUN:   2>&1 | FileCheck %s --check-prefix=NO-RANGE

# NO-RANGE: BOLT-ERROR: no common 32-bit EH frame header address range for original and emitted frames

  .attribute arch, "rv64ia"
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  .cfi_startproc
  call new_leaf
  li a7, 93
  ecall
  .cfi_endproc
  .size _start, .-_start

  .globl new_leaf
  .type new_leaf,@function
new_leaf:
  .cfi_startproc
  .cfi_personality 0x9b, personality_slot
  .cfi_lsda 0x1b, .Llsda
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
.Lcall:
  call new_helper
.Lcall_end:
  li a0, 0
  li a1, 1
.Lreturn:
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
.Lpad:
  .cfi_def_cfa_offset 16
  .cfi_offset ra, -8
  li a0, -1
  j .Lreturn
  .cfi_endproc
  .size new_leaf, .-new_leaf

  .globl new_helper
  .type new_helper,@function
new_helper:
  .cfi_startproc
  ret
  .cfi_endproc
  .size new_helper, .-new_helper

  .globl old_leaf
  .type old_leaf,@function
old_leaf:
  .cfi_startproc
  li a0, 2
  ret
  .cfi_endproc
  .size old_leaf, .-old_leaf

  .globl fini
  .type fini,@function
fini:
  .cfi_startproc
  ret
  .cfi_endproc
  .size fini, .-fini

  .data
  .globl personality_slot
personality_slot:
  .quad old_leaf
  .globl typeinfo_slot
typeinfo_slot:
  .quad typeinfo_object

  .section .rodata,"a",@progbits
typeinfo_object:
  .quad 0

  .section .gcc_except_table,"a",@progbits
  .p2align 2
.Llsda:
  .byte 0xff
  .byte 0x9b
  .uleb128 .Ltt_end - .Ltt_base
.Ltt_base:
  .byte 1
  .uleb128 .Lcallsite_end - .Lcallsite_begin
.Lcallsite_begin:
  .uleb128 .Lcall - new_leaf
  .uleb128 .Lcall_end - .Lcall
  .uleb128 .Lpad - new_leaf
  .uleb128 1
.Lcallsite_end:
  .byte 1, 0
  .p2align 2
  .long typeinfo_slot - .
.Ltt_end:

  .section .note.GNU-stack,"",@progbits
