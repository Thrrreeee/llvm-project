# REQUIRES: system-linux,bolt-runtime

# RUN: %clang %cflags -march=rv64gc -Wl,-q -o %t.exe %s
# RUN: llvm-bolt --instrument --instrumentation-file=%t.fdata -o %t.instr %t.exe
# RUN: llvm-objdump -d --no-show-raw-insn --disassemble-symbols=main %t.instr \
# RUN:   | FileCheck %s --check-prefix=INSTR
# INSTR: amoadd.d zero, a1, (a0)
# RUN: llvm-objdump -d --no-show-raw-insn -M no-aliases --disassemble-symbols=f %t.instr \
# RUN:   | FileCheck %s --check-prefix=COMPRESSED
# COMPRESSED-LABEL: <f>:
# COMPRESSED-NEXT: c.addi sp, -0x10
# COMPRESSED-NEXT: c.sdsp a0, 0x0(sp)
# COMPRESSED-NEXT: c.sdsp a1, 0x8(sp)
# COMPRESSED-NEXT: auipc a0,
# COMPRESSED-NEXT: addi a0, a0,
# COMPRESSED-NEXT: c.li a1, 0x1
# COMPRESSED-NEXT: amoadd.d zero, a1, (a0)
# COMPRESSED-NEXT: c.ldsp a0, 0x0(sp)
# COMPRESSED-NEXT: c.ldsp a1, 0x8(sp)
# COMPRESSED-NEXT: c.addi sp, 0x10
# COMPRESSED-NEXT: c.jr ra

## Run the profiled binary and check that the profile reports at least that `f`
## has been called.
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: cat %t.fdata | FileCheck %s
# CHECK: f 0 0 1{{$}}

## Check BOLT works with this profile
# RUN: llvm-bolt --data %t.fdata --reorder-blocks=cache -o %t.bolt %t.exe
# RUN: %t.bolt

    .text
    .globl main
    .type main, @function
main:
    addi sp, sp, -8
    sd ra, 0(sp)
    call f
    ld ra, 0(sp)
    addi sp, sp, 8
    li a0, 0
    ret
    .size main, .-main

    .globl f
    .type f, @function
f:
    ret
    .size f, .-f
