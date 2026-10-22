# REQUIRES: system-linux,bolt-runtime

## Two dispatches share a PIC jump table. Instrumentation duplicates the table
## for its second use, so the far-data pass must preserve both symbolic bases.
## The unrelated fixed-data reference in the same function still needs a slot.
# RUN: split-file %s %t.dir
# RUN: %clang %cflags -pie -Wl,-q,--no-relax -o %t.exe %t.dir/input.s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --funcs=main,dispatch --instrumentation-file=%t.fdata \
# RUN:   --print-jump-tables -o %t.instr 2>&1 | FileCheck %s
# RUN: %python %t.dir/check.py %t.exe %t.instr
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: llvm-bolt %t.exe --data=%t.fdata --funcs=main,dispatch \
# RUN:   --reorder-blocks=cache -o %t.bolt
# RUN: %t.bolt

# CHECK: RISC-V far-data slots replaced 1 AUIPC references and restored 1 low operands
# CHECK: PIC Jump table PIC_JT{{(/1)?}} for function dispatch
# CHECK: PIC Jump table {{.*}}duplicatedJT{{.*}} for function dispatch
# PROFILE-COUNT-2: 1 main {{[0-9a-f]+}} 1 dispatch 0 0 1{{$}}

#--- input.s
  .option norelax
  .text
  .globl main
  .type main,@function
main:
  .cfi_startproc
  addi sp, sp, -16
  .cfi_def_cfa_offset 16
  sd ra, 8(sp)
  .cfi_offset ra, -8
  li a0, 0
  li a1, 0
  call dispatch
  li t0, 20
  bne a0, t0, .Lfail
  li a0, 2
  li a1, 1
  call dispatch
  li t0, 22
  bne a0, t0, .Lfail
  li a0, 0
  j .Lreturn
.Lfail:
  li a0, 1
.Lreturn:
  ld ra, 8(sp)
  .cfi_restore ra
  addi sp, sp, 16
  .cfi_def_cfa_offset 0
  ret
  .cfi_endproc
  .size main, .-main

  .globl dispatch
  .type dispatch,@function
dispatch:
  .cfi_startproc
.Lvalue_hi:
  auipc t2, %pcrel_hi(value)
  ld t3, %pcrel_lo(.Lvalue_hi)(t2)
  li t4, 37
  bne t3, t4, .Lbad
  bnez a1, .Lsecond
.Lfirst_hi:
  auipc a4, %pcrel_hi(PIC_JT)
  addi a4, a4, %pcrel_lo(.Lfirst_hi)
  slli a2, a0, 2
  add a2, a2, a4
  lw a2, 0(a2)
  add a2, a2, a4
  jr a2
.Lsecond:
.Lsecond_hi:
  auipc a4, %pcrel_hi(PIC_JT)
  addi a4, a4, %pcrel_lo(.Lsecond_hi)
  slli a2, a0, 2
  add a2, a2, a4
  lw a2, 0(a2)
  add a2, a2, a4
  jr a2
.Lcase0:
  li a0, 20
  ret
.Lcase1:
  li a0, 21
  ret
.Lcase2:
  li a0, 22
  ret
.Lbad:
  li a0, -1
  ret
  .cfi_endproc
  .size dispatch, .-dispatch

  .section .rodata,"a",@progbits
  .p2align 3
  .type value,@object
value:
  .quad 37
  .size value, .-value
  .globl PIC_JT
  .hidden PIC_JT
  .type PIC_JT,@object
PIC_JT:
  .word .Lcase0 - PIC_JT
  .word .Lcase1 - PIC_JT
  .word .Lcase2 - PIC_JT
  .size PIC_JT, .-PIC_JT

## Retain a preexisting dynamic RELATIVE relocation for the far-data mode.
  .data
  .p2align 3
  .quad value

  .section .note.GNU-stack,"",@progbits

#--- check.py
import struct
import sys


class ELF:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        h = struct.unpack_from("<16sHHIQQQIHHHHHH", self.data)
        self.sections = [struct.unpack_from("<IIQQQQIIQQ", self.data,
                                           h[6] + i * h[11])
                         for i in range(h[12])]
        self.symbols = {}
        for section in self.sections:
            if section[1] != 2:
                continue
            strings = self.sections[section[6]][4]
            for off in range(section[4], section[4] + section[5], section[9]):
                name, _, _, _, value, size = struct.unpack_from("<IBBHQQ", self.data, off)
                begin = strings + name
                name = self.data[begin:self.data.index(b"\0", begin)].decode()
                self.symbols[name] = (value, size)

    def word(self, address):
        for section in self.sections:
            if section[1] != 8 and section[3] <= address < section[3] + section[5]:
                return struct.unpack_from("<I", self.data, section[4] + address - section[3])[0]
        raise AssertionError(hex(address))


def signed(value, bits):
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def table_address(elf, label):
    address = elf.symbols[label][0]
    end = sum(elf.symbols["dispatch"])
    base = None
    # A block label can precede an inserted counter. Find the final AUIPC a4
    # before this dispatch's JR a2, rather than interpreting the counter base.
    while address < end:
        instruction = elf.word(address)
        if instruction & 0xffff == 0x8602 or instruction == 0x00060067:
            break
        if instruction & 0xfff == 0x717:
            base = address
        address += 4 if instruction & 3 == 3 else 2
    assert address < end and base is not None
    high, low = elf.word(base), elf.word(base + 4)
    reg = 14
    if low & 3 == 3:
        assert low & 0x707f == 0x13
        assert (low >> 7) & 31 == reg and (low >> 15) & 31 == reg
        immediate = signed(low >> 20, 12)
    else:
        assert low & 0xe003 == 1 and (low >> 7) & 31 == reg
        immediate = signed(((low >> 7) & 32) | ((low >> 2) & 31), 6)
    return base + signed(high & 0xfffff000, 32) + immediate


old, new = (ELF(path) for path in sys.argv[1:])
original = old.symbols["PIC_JT"][0]
first = table_address(new, ".Lfirst_hi")
second = table_address(new, ".Lsecond_hi")
assert table_address(old, ".Lfirst_hi") == original
assert table_address(old, ".Lsecond_hi") == original
assert len({original, first, second}) == 3
start, size = new.symbols["dispatch"]
for table in (first, second):
    for index in range(3):
        target = table + signed(new.word(table + index * 4), 32)
        assert start <= target < start + size
value_high = new.symbols[".Lvalue_hi"][0]
assert new.word(value_high) & 0x7f == 0x17
assert new.word(value_high + 4) & 0x707f == 0x3003
