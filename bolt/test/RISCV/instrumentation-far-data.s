# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## A relocated AUIPC must preserve its original high base, including all I/S
## low consumers, numeric consumers, and users in another basic block.
# RUN: split-file %s %t.dir
# RUN: llvm-mc -triple=riscv64 -mattr=+a -filetype=obj %t.dir/input.s -o %t.o
# RUN: ld.lld --emit-relocs --no-relax -pie -e _start --dynamic-linker=ld.so \
# RUN:   --init=fini --fini=fini --section-start=.text=0x10000 --section-start=.rodata=0x120000 \
# RUN:   --section-start=.data=0x130800 %t.o -o %t
# RUN: not llvm-bolt %t --instrument --custom-allocation-vma=0x90000000 \
# RUN:   -o %t.baseline 2>&1 | FileCheck %s --check-prefix=BASELINE
# RUN: llvm-bolt %t --instrument --riscv-instrumentation-far-data \
# RUN:   --custom-allocation-vma=0x90000000 -o %t.far 2>&1 | FileCheck %s
# RUN: %python %t.dir/check.py %t %t.far
# RUN: llvm-nm %t.far | FileCheck %s --check-prefix=NO-TABLES-GETTER \
# RUN:   --implicit-check-not=__bolt_instr_tables_getter
# RUN: not llvm-bolt %t --riscv-instrumentation-far-data -o %t.invalid \
# RUN:   2>&1 | FileCheck %s --check-prefix=GUARD
# RUN: not llvm-bolt %t --instrument --riscv-instrumentation-far-data \
# RUN:   --inline-all -o %t.invalid 2>&1 | FileCheck %s --check-prefix=INLINE

# BASELINE: is out of range of R_RISCV_PCREL_HI20
# CHECK: RISC-V far-data slots replaced 3 AUIPC references and restored 6 low operands
# GUARD: --riscv-instrumentation-far-data requires RISC-V64 --instrument
# INLINE: --riscv-instrumentation-far-data does not support inlining
# NO-TABLES-GETTER: _start

#--- input.s
  .attribute arch, "rv64ia"
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  li a0, 0
  call multi
  li a7, 93
  ecall
  .size _start, .-_start

  .globl multi
  .type multi,@function
multi:
first_hi:
  auipc s1, %pcrel_hi(roval)
first_ld:
  ld t3, %pcrel_lo(first_hi)(s1)
first_add:
  addi s4, s1, %pcrel_lo(first_hi)
  ld t4, 0(s4)
  bne t3, t4, .Lbad
numeric_add:
  addi t4, s1, 17
  sub t4, t4, s1
  li t5, 17
  bne t4, t5, .Lbad
  bnez a0, .Lcross
  nop
.Lcross:
cross_lw:
  lw t5, %pcrel_lo(first_hi)(s1)
  bne t5, t3, .Lbad
write_hi:
  auipc s2, %pcrel_hi(outval)
write_sd:
  sd t3, %pcrel_lo(write_hi)(s2)
write_add:
  addi s5, s2, %pcrel_lo(write_hi)
  ld t6, 0(s5)
  bne t6, t3, .Lbad
got_hi:
  auipc s3, %got_pcrel_hi(roval)
got_ld:
  ld t4, %pcrel_lo(got_hi)(s3)
  bne t4, s4, .Lbad
  li a0, 0
  ret
.Lbad:
  li a0, 1
  ret
  .size multi, .-multi

  .globl fini
  .type fini,@function
fini:
  ret
  .size fini, .-fini

  .section .rodata,"a",@progbits
  .p2align 3
  .type roval,@object
roval:
  .quad 37
  .size roval, .-roval
  .data
  .p2align 3
  .type outval,@object
outval:
  .quad 0
  .size outval, .-outval
## Force a preexisting dynamic RELATIVE relocation; there are no empty slots.
pointer:
  .quad roval

#--- check.py
import mmap
import struct
import sys

class ELF:
    def __init__(self, path):
        self.file = open(path, "rb")
        self.data = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
        h = struct.unpack_from("<16sHHIQQQIHHHHHH", self.data)
        sections = [struct.unpack_from("<IIQQQQIIQQ", self.data, h[6] + i*h[11])
                    for i in range(h[12])]
        strings = sections[h[13]][4]
        self.sections = {self.string(strings+s[0]): s for s in sections}
        self.symbols = {}
        for s in sections:
            if s[1] != 2:
                continue
            strings = sections[s[6]][4]
            for off in range(s[4], s[4]+s[5], s[9]):
                n, _, _, _, value, size = struct.unpack_from("<IBBHQQ", self.data, off)
                self.symbols[self.string(strings+n)] = (value, size)
        d = self.sections[".dynamic"]
        self.dynamic = dict(struct.unpack_from("<qQ", self.data, off)
                            for off in range(d[4], d[4]+d[5], 16))

    def string(self, off):
        return self.data[off:self.data.find(b"\0", off)].decode()

    def word(self, address):
        for s in self.sections.values():
            if s[1] != 8 and s[3] <= address < s[3]+s[5]:
                return struct.unpack_from("<I", self.data, s[4]+address-s[3])[0]
        raise AssertionError(hex(address))

    def named_word(self, name):
        return self.word(self.symbols[name][0])

def signed(value, bits):
    return (value ^ (1 << (bits-1))) - (1 << (bits-1))

def low(word):
    if word & 0x7f in (0x23, 0x27):
        return signed(((word >> 20) & 0xfe0) | ((word >> 7) & 31), 12)
    return signed(word >> 20, 12)

old, new = (ELF(p) for p in sys.argv[1:])
counters = new.sections[".bolt.instr.counters"]
getter = new.symbols["__bolt_instr_locations_getter"][0]
hi, lo = new.word(getter), new.word(getter+4)
assert hi & 0x7f == 0x17 and lo & 0x707f == 0x13
locations = getter + signed(hi & 0xfffff000, 32) + low(lo)
assert counters[3] < locations and locations % 4096 == 0
rela = next(s for s in new.sections.values() if s[3] == new.dynamic[7])
assert rela[1] == 4 and rela[5] == new.dynamic[8] and rela[9] == 24
assert rela[6] != 0 and rela[8] == 8
entries = [struct.unpack_from("<QQq", new.data, off)
           for off in range(rela[4], rela[4]+rela[5], 24)]
assert all(info == 3 for _, info, _ in entries[:new.dynamic[0x6ffffff9]])
slots = {off: addend for off, info, addend in entries
         if counters[3] <= off < locations and info == 3}
assert len(slots) == 3
for name in ("first_hi", "write_hi", "got_hi"):
    original = old.symbols[name][0]
    base = original + signed(old.word(original) & 0xfffff000, 32)
    address = new.symbols[name][0]
    hi, load = new.word(address), new.word(address+4)
    assert hi & 0x7f == 0x17 and load & 0x707f == 0x3003
    reg = (hi >> 7) & 31
    assert (load >> 7) & 31 == reg and (load >> 15) & 31 == reg
    slot = address + signed(hi & 0xfffff000, 32) + low(load)
    assert slots[slot] == base, (name, hex(slot), hex(base), slots)
lows = ("first_ld", "first_add", "cross_lw", "write_sd", "write_add", "got_ld")
for name in lows:
    assert new.named_word(name) == old.named_word(name), name
values = [low(old.named_word(name)) for name in lows]
assert any(v < 0 for v in values) and any(v > 0 for v in values), values
start, size = new.symbols["multi"]
assert old.named_word("numeric_add") in [new.word(a) for a in range(start, start+size, 4)]
