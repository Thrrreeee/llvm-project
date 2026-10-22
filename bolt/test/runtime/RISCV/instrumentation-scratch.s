# REQUIRES: system-linux,bolt-runtime

## Prove scratch only before the first use in the actual insertion block.
## All variants preserve the arithmetic results and produce usable profiles.
# RUN: %clang %cflags -march=rv64gc -Wl,-q -o %t.exe %s
# RUN: %t.exe | FileCheck %s --check-prefix=RESULT
# RUN: llvm-bolt %t.exe --instrument --instrumentation-file=%t.fdata -o %t.instr
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases %t.instr \
# RUN:   | FileCheck %s --check-prefix=CODE
# RUN: rm -f %t.fdata
# RUN: %t.instr | FileCheck %s --check-prefix=RESULT
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: llvm-bolt %t.exe --data=%t.fdata --reorder-blocks=cache -o %t.opt
# RUN: %t.opt | FileCheck %s --check-prefix=RESULT
# RUN: llvm-bolt %t.exe --instrument --conservative-instrumentation \
# RUN:   --instrumentation-file=%t.cons.fdata -o %t.cons
# RUN: %t.cons | FileCheck %s --check-prefix=RESULT
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases --disassemble-symbols=critical %t.cons \
# RUN:   | FileCheck %s --check-prefix=CRITICAL

# RESULT: 42
# PROFILE-DAG: two_dead 0 0 1{{$}}
# PROFILE-DAG: one_dead 0 0 1{{$}}
# PROFILE-DAG: no_dead 0 0 1{{$}}
# PROFILE-DAG: cfi_register 0 0 1{{$}}

# CODE-LABEL: <two_dead>:
# CODE-NEXT: [[#%x,TWO:]]: auipc a0,
# CODE-NEXT: [[#TWO+4]]: addi a0, a0,
# CODE-NEXT: [[#TWO+8]]: c.li a1, 0x1
# CODE-NEXT: [[#TWO+10]]: amoadd.d zero, a1, (a0)
# CODE-NEXT: [[#TWO+14]]: c.li a0, 0x15

# CODE-LABEL: <one_dead>:
# CODE-NEXT: [[#%x,ONE:]]: c.addi sp, -0x10
# CODE-NEXT: [[#ONE+2]]: c.sdsp a0, 0x0(sp)
# CODE-NEXT: [[#ONE+4]]: auipc a1,
# CODE-NEXT: [[#ONE+8]]: addi a1, a1,
# CODE-NEXT: [[#ONE+12]]: c.li a0, 0x1
# CODE-NEXT: [[#ONE+14]]: amoadd.d zero, a0, (a1)
# CODE-NEXT: [[#ONE+18]]: c.ldsp a0, 0x0(sp)
# CODE-NEXT: [[#ONE+20]]: c.addi sp, 0x10
# CODE-NEXT: [[#ONE+22]]: c.li a1, 0x7

# CODE-LABEL: <no_dead>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <rmw>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <prior_use>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <load_dead>:
# CODE-NEXT: auipc a0,
# CODE-LABEL: <load_self>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <cfi_register>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: auipc a1,
# CODE-LABEL: <cfi_cie>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: auipc a1,
# CODE-LABEL: <cfi_escape>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <call_barrier>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <ecall_barrier>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <csr_barrier>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <unknown_barrier>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)
# CODE-LABEL: <temp_dead>:
# CODE-NEXT: auipc t0,
# CODE-NEXT: addi t0, t0,
# CODE-NEXT: c.li t1, 0x1
# CODE-NEXT: amoadd.d zero, t1, (t0)
# CODE-LABEL: <scan_limit>:
# CODE-NEXT: c.addi sp, -0x10
# CODE-NEXT: c.sdsp a0, 0x0(sp)
# CODE-NEXT: c.sdsp a1, 0x8(sp)

## The new block on the critical edge has no proof of dead input registers.
# CRITICAL-LABEL: <critical>:
# CRITICAL: c.addi sp, -0x10
# CRITICAL-NEXT: c.sdsp a0, 0x0(sp)
# CRITICAL-NEXT: c.sdsp a1, 0x8(sp)

  .option norelax
  .text
  .globl main
  .type main,@function
main:
  addi sp, sp, -16
  sd ra, 8(sp)
  call two_dead
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 35
  call one_dead
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 35
  li a1, 7
  call no_dead
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 35
  li a1, 5
  call rmw
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 35
  li a1, 6
  lla a2, value
  call prior_use
  li t0, 42
  bne a0, t0, .Lfail
  ld t1, 0(a2)
  li t0, 6
  bne t1, t0, .Lfail
  li t0, 35
  sd t0, 0(a2)
  call load_dead
  li t0, 42
  bne a0, t0, .Lfail
  lla a0, value
  li a1, 7
  call load_self
  li t0, 42
  bne a0, t0, .Lfail
  call cfi_register
  li t0, 42
  bne a0, t0, .Lfail
  call cfi_cie
  li t0, 42
  bne a0, t0, .Lfail
  call cfi_escape
  li t0, 42
  bne a0, t0, .Lfail
  call call_barrier
  li t0, 42
  bne a0, t0, .Lfail
  li a7, 172 # getpid
  call ecall_barrier
  li t0, 42
  bne a0, t0, .Lfail
  call unknown_barrier
  li t0, 42
  bne a0, t0, .Lfail
  call temp_dead
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 10
  call scan_limit
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 0
  call critical
  li t0, 42
  bne a0, t0, .Lfail
  li a0, 1
  call critical
  li t0, 42
  bne a0, t0, .Lfail
  lla a0, format
  li a1, 42
  call printf
  li a0, 0
  j .Lexit
.Lfail:
  li a0, 1
.Lexit:
  ld ra, 8(sp)
  addi sp, sp, 16
  ret
  .size main, .-main

  .macro begin name
  .globl \name
  .type \name,@function
\name:
  .endm
  .macro end name
  .size \name, .-\name
  .endm

  begin two_dead
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  end two_dead

  begin one_dead
  li a1, 7
  add a0, a0, a1
  ret
  end one_dead

  begin no_dead
  add a0, a0, a1
  ret
  end no_dead

  begin rmw
  c.addi a0, 1
  c.addi a1, 1
  add a0, a0, a1
  ret
  end rmw

  begin prior_use
  sd a1, 0(a2)
  li a1, 7
  add a0, a0, a1
  ret
  end prior_use

  begin load_dead
  ld a0, 0(a2)
  li a1, 7
  add a0, a0, a1
  ret
  end load_dead

  begin load_self
  ld a0, 0(a0)
  add a0, a0, a1
  ret
  end load_self

  begin cfi_register
  .cfi_startproc
  li a0, 21
  li a1, 21
  .cfi_register s1, a0
  add a0, a0, a1
  ret
  .cfi_endproc
  end cfi_register

  begin cfi_cie
  .cfi_startproc
  .cfi_register s1, a0 # At function entry, BOLT stores this rule in the CIE program.
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  .cfi_endproc
  end cfi_cie

  begin cfi_escape
  .cfi_startproc
  .cfi_escape 0x16, 0x12, 0x01, 0x30 # DW_CFA_val_expression s2, DW_OP_lit0
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  .cfi_endproc
  end cfi_escape

  begin call_barrier
  addi sp, sp, -16
  sd ra, 8(sp)
  call no_dead
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ld ra, 8(sp)
  addi sp, sp, 16
  ret
  end call_barrier

  begin ecall_barrier
  ecall
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  end ecall_barrier

  begin csr_barrier
  csrr zero, cycle
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  end csr_barrier

  begin unknown_barrier
  mul t0, a0, a1
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  end unknown_barrier

  begin temp_dead
  li t0, 21
  li t1, 21
  add a0, t0, t1
  ret
  end temp_dead

  begin scan_limit
  .rept 32
  c.addi a0, 1
  .endr
  li a1, 0
  add a0, a0, a1
  ret
  end scan_limit

  begin critical
  beqz a0, .Ljoin
  li a2, 1
.Ljoin:
  li a0, 21
  li a1, 21
  add a0, a0, a1
  ret
  end critical

  .data
  .p2align 3
value:
  .quad 35
format:
  .asciz "%ld\n"
  .section .note.GNU-stack,"",@progbits
