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
                name, _, _, index, address, size = struct.unpack_from(
                    "<IBBHQQ", self.data, offset
                )
                begin = strings + name
                name = self.data[begin:self.data.index(b"\0", begin)].decode()
                self.symbols[name] = (index, address, size)

    def address(self, name):
        return self.symbols[name][1]

    def function(self, name):
        index, address, size = self.symbols[name]
        section = self.sections[index]
        offset = section[4] + address - section[3]
        return address, size, self.data[offset:offset + size]


def signed(value, bits):
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def target(pc, high, low):
    return (pc + signed(high & 0xfffff000, 32) + signed(low >> 20, 12)) & ~1


old, early, normal = (ELF(path) for path in sys.argv[1:])
names = ["padding", "main", "callee_secondary", "callee_primary"]
assert sorted(names, key=normal.address) == names
expected = ["callee_secondary", "callee_primary", "main", "padding"]
assert sorted(names, key=early.address) == expected

old_address, old_size, before = old.function("preserved")
targets = ["callee_alias", "callee_secondary_entry"]
pairs = {}
for offset in range(0, old_size - 7, 4):
    high, low = struct.unpack_from("<II", before, offset)
    if (high & 0x7f != 0x17 or low & 0x707f != 0x67
            or (high >> 7) & 31 != (low >> 15) & 31 or (low >> 7) & 31 != 1):
        continue
    for name in targets:
        if target(old_address + offset, high, low) == old.address(name):
            assert name not in pairs
            pairs[name] = offset
assert set(pairs) == set(targets)

for new in (early, normal):
    new_address, new_size, after = new.function("preserved")
    assert (new_address, new_size) == (old_address, old_size)
    unchanged = bytearray(after)
    for name, offset in pairs.items():
        old_high, old_low = struct.unpack_from("<II", before, offset)
        new_high, new_low = struct.unpack_from("<II", after, offset)
        assert old_high & 0xfff == new_high & 0xfff
        assert old_low & 0xfffff == new_low & 0xfffff
        assert target(old_address + offset, new_high, new_low) == new.address(name)
        assert new.address(name) != old.address(name)
        unchanged[offset:offset + 8] = before[offset:offset + 8]
    assert unchanged == before
    assert new.address("callee_alias") == new.address("callee_primary")
    secondary, size, _ = new.function("callee_secondary")
    assert secondary < new.address("callee_secondary_entry") < secondary + size
