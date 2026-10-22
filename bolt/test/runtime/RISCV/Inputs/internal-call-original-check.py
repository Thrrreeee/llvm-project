"""Check that ignoring an internal-call function preserves its original body."""

import struct
import sys


class ELF:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        header = struct.unpack_from("<16sHHIQQQIHHHHHH", self.data)
        self.sections = [
            struct.unpack_from("<IIQQQQIIQQ", self.data, header[6] + i * header[11])
            for i in range(header[12])
        ]
        self.symbols = {}
        for section in self.sections:
            if section[1] != 2:
                continue
            strings = self.sections[section[6]][4]
            for offset in range(section[4], section[4] + section[5], section[9]):
                name, info, _, index, address, size = struct.unpack_from(
                    "<IBBHQQ", self.data, offset
                )
                if info & 15 != 2:
                    continue
                begin = strings + name
                name = self.data[begin:self.data.index(b"\0", begin)].decode()
                self.symbols[name] = (index, address, size)

    def function(self, name):
        index, address, size = self.symbols[name]
        section = self.sections[index]
        offset = section[4] + address - section[3]
        return address, size, self.data[offset:offset + size]


def call_target(address, offset, high, low):
    upper = high & 0xfffff000
    if upper & 0x80000000:
        upper -= 1 << 32
    lower = low >> 20
    if lower & 0x800:
        lower -= 1 << 12
    return (address + offset + upper + lower) & ~1


original, rewritten = (ELF(path) for path in sys.argv[1:])
address, size, before = original.function("large")
new_address, new_size, after = rewritten.function("large")
assert (new_address, new_size) == (address, size)
old_callee, old_callee_size, _ = original.function("body_callee")
new_callee, new_callee_size, _ = rewritten.function("body_callee")
assert new_callee != old_callee
assert new_callee_size > old_callee_size

calls = []
for offset in range(0, size - 7, 4):
    high, low = struct.unpack_from("<II", before, offset)
    if (high & 0x7f != 0x17 or low & 0x707f != 0x67
            or (high >> 7) & 31 != (low >> 15) & 31 or (low >> 7) & 31 != 1):
        continue
    if call_target(address, offset, high, low) == old_callee:
        calls.append(offset)
assert len(calls) == 1, calls
offset = calls[0]
assert before[:offset] == after[:offset]
assert before[offset + 8:] == after[offset + 8:]
old_high, old_low = struct.unpack_from("<II", before, offset)
new_high, new_low = struct.unpack_from("<II", after, offset)
assert old_high & 0xfff == new_high & 0xfff
assert old_low & 0xfffff == new_low & 0xfffff
assert call_target(address, offset, new_high, new_low) == new_callee
