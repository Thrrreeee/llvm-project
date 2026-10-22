# REQUIRES: system-linux,bolt-runtime

## A slot prefix spanning multiple pages must survive runtime counter mapping.
## Verify the ELF table metadata and relative-relocation prefix, then execute
## every transformed address use and read the generated profile back into BOLT.
# RUN: split-file %s %t.dir
# RUN: %clang %cflags -march=rv64gc -Wl,-q -o %t.exe %t.dir/input.s
# RUN: %t.exe
# RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
# RUN:   --instrumentation-file=%t.fdata -o %t.instr
# RUN: %python %t.dir/check.py %t.exe %t.instr
# RUN: rm -f %t.fdata
# RUN: %t.instr
# RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
# RUN: llvm-bolt %t.exe --data=%t.fdata -o %t.opt
# RUN: %t.opt

# PROFILE: main 0 0 1{{$}}

#--- input.s
  .option norelax
  .option norvc
  .text
  .globl main
  .type main,@function
main:
  .cfi_startproc
  li a0, 0
  li t2, 35
  .rept 350
  lla t0, value1
  ld t1, 0(t0)
  xor t1, t1, t2
  or a0, a0, t1
  .endr
  li t2, 7
  .rept 350
  lla t0, value2
  ld t1, 0(t0)
  xor t1, t1, t2
  or a0, a0, t1
  .endr
  ret
  .cfi_endproc
  .size main, .-main

  .data
  .p2align 3
  .type value1,@object
value1:
  .quad 35
  .size value1, .-value1
  .space 8192
  .type value2,@object
value2:
  .quad 7
  .size value2, .-value2
  .quad value1
  .section .note.GNU-stack,"",@progbits

#--- check.py
import struct
import sys


def elf(path):
    with open(path, "rb") as stream:
        data = stream.read()
    header = struct.unpack_from("<16sHHIQQQIHHHHHH", data)
    sections = [struct.unpack_from("<IIQQQQIIQQ", data,
                                   header[6] + i * header[11])
                for i in range(header[12])]
    names = sections[header[13]]

    def string(offset):
        return data[offset:data.index(b"\0", offset)].decode()

    by_name = {string(names[4] + s[0]): s for s in sections}
    dynamic = by_name[".dynamic"]
    tags = dict(struct.unpack_from("<QQ", data, offset)
                for offset in range(dynamic[4], dynamic[4] + dynamic[5], 16))
    symbols = by_name[".symtab"]
    strings = sections[symbols[6]]
    values = {}
    for offset in range(symbols[4], symbols[4] + symbols[5], symbols[9]):
        symbol = struct.unpack_from("<IBBHQQ", data, offset)
        values[string(strings[4] + symbol[0])] = symbol[4]
    return data, sections, by_name, tags, values


old, _, old_sections, _, _ = elf(sys.argv[1])
data, sections, named, tags, symbols = elf(sys.argv[2])
rela = named[".rela.dyn"]
counters = named[".bolt.instr.counters"]
getter = symbols["__bolt_instr_locations_getter"]
getter_section = next(s for s in sections if s[3] <= getter < s[3] + s[5]
                      and s[2] & 4)
getter_offset = getter_section[4] + getter - getter_section[3]
high, low = struct.unpack_from("<II", data, getter_offset)
assert high & 0x7f == 0x17 and low & 0x707f == 0x13
assert (high >> 7) & 31 == (low >> 15) & 31 == (low >> 7) & 31


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


locations = getter + signed(high & 0xfffff000, 32) + signed(low >> 20, 12)
assert locations % 4096 == 0
assert locations - counters[3] >= 8192
assert rela[1] == 4 and rela[9] == 24 and rela[8] == 8
assert sections[rela[6]][1] == 11  # sh_link points to SHT_DYNSYM.
assert tags[7] == rela[3] and tags[8] == rela[5] and tags[9] == 24
entries = [struct.unpack_from("<QQq", data, offset)
           for offset in range(rela[4], rela[4] + rela[5], 24)]
slots = [r for r in entries if counters[3] <= r[0] < locations]
assert len(slots) > 512
assert all(info == 3 for _, info, _ in slots)  # RELATIVE, symbol index 0.
assert rela[5] == old_sections[".rela.dyn"][5] + len(slots) * 24
assert len({offset for offset, _, _ in slots}) == len(slots)
relative_count = tags.get(0x6ffffff9, 0)
assert relative_count >= len(slots)
assert all(info == 3 for _, info, _ in entries[:relative_count])
assert all(info != 3 for _, info, _ in entries[relative_count:])
