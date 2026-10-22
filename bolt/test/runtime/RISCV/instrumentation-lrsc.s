# REQUIRES: system-linux,bolt-runtime

## Counter spills and AMOs inside an LR/SC sequence can remove its eventual
## success guarantee. The forward diamond forces default spanning-tree
## instrumentation to place counters between LR and SC. Preserve the whole
## function for both widths and all ordering variants, including unmatched
## LR/SC instructions; ordinary AMO instructions must remain instrumentable.
# RUN: %clang %cflags -Wl,-q -o %t.exe %s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --instrumentation-file=%t.fdata -v=2 -o %t.instr \
# RUN:   | FileCheck %s --check-prefix=LOG
# RUN: llvm-objdump -d --no-show-raw-insn --disassemble-symbols=atomic_w,atomic_w_aq,atomic_w_rl,atomic_w_aqrl,atomic_d,atomic_d_aq,atomic_d_rl,atomic_d_aqrl,lr_only,sc_only %t.instr \
# RUN:   | FileCheck %s --check-prefix=ATOMIC --implicit-check-not=amoadd
# RUN: llvm-objdump -d --no-show-raw-insn --disassemble-symbols=main %t.instr \
# RUN:   | FileCheck %s --check-prefix=COUNTER
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: llvm-bolt %t.exe --instrument --conservative-instrumentation --instrumentation-file=%t.cons.fdata -v=2 -o %t.cons.instr \
# RUN:   | FileCheck %s --check-prefix=LOG
# RUN: llvm-objdump -d --no-show-raw-insn --disassemble-symbols=atomic_w,atomic_w_aq,atomic_w_rl,atomic_w_aqrl,atomic_d,atomic_d_aq,atomic_d_rl,atomic_d_aqrl,lr_only,sc_only %t.cons.instr \
# RUN:   | FileCheck %s --check-prefix=ATOMIC --implicit-check-not=amoadd
# RUN: rm -f %t.cons.fdata
# RUN: %t.cons.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.cons.fdata
# RUN: llvm-bolt %t.exe --data=%t.fdata --reorder-blocks=cache -o %t.bolt
# RUN: %t.bolt

# COUNTER: amoadd.d zero, a1, (a0)
# PROFILE: ordinary_amo 0 0 1{{$}}

# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_w containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_w_aq containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_w_rl containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_w_aqrl containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_d containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_d_aq containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_d_rl containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function atomic_d_aqrl containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function lr_only containing a RISC-V LR/SC instruction
# LOG-DAG: BOLT-INSTRUMENTER: skipping function sc_only containing a RISC-V LR/SC instruction

# ATOMIC-LABEL: <atomic_w>:
# ATOMIC-NEXT: lr.w a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.w a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_w_aq>:
# ATOMIC-NEXT: lr.w.aq a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.w.aq a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_w_rl>:
# ATOMIC-NEXT: lr.w.rl a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.w.rl a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_w_aqrl>:
# ATOMIC-NEXT: lr.w.aqrl a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.w.aqrl a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_d>:
# ATOMIC-NEXT: lr.d a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.d a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_d_aq>:
# ATOMIC-NEXT: lr.d.aq a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.d.aq a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_d_rl>:
# ATOMIC-NEXT: lr.d.rl a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.d.rl a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <atomic_d_aqrl>:
# ATOMIC-NEXT: lr.d.aqrl a1, (a0)
# ATOMIC-NEXT: beqz a2,
# ATOMIC-NEXT: addi a1, a1, {{(0x)?1}}
# ATOMIC-NEXT: j
# ATOMIC-NEXT: addi a1, a1, {{(0x)?2}}
# ATOMIC-NEXT: sc.d.aqrl a3, a1, (a0)
# ATOMIC-NEXT: bnez a3,
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <lr_only>:
# ATOMIC-NEXT: lr.w.rl t0, (a0)
# ATOMIC-NEXT: ret
# ATOMIC-LABEL: <sc_only>:
# ATOMIC-NEXT: sc.d.aq t0, t1, (a0)
# ATOMIC-NEXT: ret

  .option norvc
  .option norelax
  .text
  .globl main
  .type main,@function
main:
  addi sp, sp, -16
  sd ra, 0(sp)
  lla a0, value
  li a2, 1
  call atomic_w
  li a2, 0
  call atomic_w
  call atomic_w_aq
  call atomic_w_rl
  call atomic_w_aqrl
  call atomic_d
  call atomic_d_aq
  call atomic_d_rl
  call atomic_d_aqrl
  call ordinary_amo
  ld a0, 0(a0)
  addi a0, a0, -18
  snez a0, a0
  ld ra, 0(sp)
  addi sp, sp, 16
  ret
  .size main, .-main

  .macro atomic name, width, ordering
  .globl \name
  .type \name,@function
\name:
.Lretry\@:
  lr.\width\()\ordering a1, (a0)
  beqz a2, .Lother\@
  addi a1, a1, 1
  j .Lstore\@
.Lother\@:
  addi a1, a1, 2
.Lstore\@:
  sc.\width\()\ordering a3, a1, (a0)
  bnez a3, .Lretry\@
  ret
  .size \name, .-\name
  .endm

  atomic atomic_w, w
  atomic atomic_w_aq, w, .aq
  atomic atomic_w_rl, w, .rl
  atomic atomic_w_aqrl, w, .aqrl
  atomic atomic_d, d
  atomic atomic_d_aq, d, .aq
  atomic atomic_d_rl, d, .rl
  atomic atomic_d_aqrl, d, .aqrl

  .globl lr_only
  .type lr_only,@function
lr_only:
  lr.w.rl t0, (a0)
  ret
  .size lr_only, .-lr_only

  .globl sc_only
  .type sc_only,@function
sc_only:
  sc.d.aq t0, t1, (a0)
  ret
  .size sc_only, .-sc_only

  .globl ordinary_amo
  .type ordinary_amo,@function
ordinary_amo:
  li a1, 1
  amoadd.d zero, a1, (a0)
  ret
  .size ordinary_amo, .-ordinary_amo

  .data
  .p2align 3
value:
  .quad 0

  .section .note.GNU-stack,"",@progbits

