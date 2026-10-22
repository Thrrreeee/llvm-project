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


def calls_to(elf, name, target):
    address, size, data = elf.function(name)
    calls = []
    offset = 0
    while offset + 4 <= size:
        high = struct.unpack_from("<I", data, offset)[0]
        if high & 0x7f == 0x17 and offset + 8 <= size:
            low = struct.unpack_from("<I", data, offset + 4)[0]
            if (low & 0x707f == 0x67
                    and (high >> 7) & 31 == (low >> 15) & 31):
                value = (address + offset + signed(high & 0xfffff000, 32)
                         + signed(low >> 20, 12)) & ~1
                if value == target:
                    calls.append((low >> 7) & 31)
        offset += 4 if high & 3 == 3 else 2
    return calls


old, early, normal = (ELF(path) for path in sys.argv[1:])
names = ["padding", "direct_caller", "main", "tail_caller", "low_caller", "atomic"]
assert sorted(names, key=normal.address) == names
expected = ["atomic", "low_caller", "direct_caller", "tail_caller", "padding", "main"]
assert sorted(names, key=early.address) == expected

assert old.address("fixed_low") < old.address("fixed_leaf")
for new in (early, normal):
    assert new.function("fixed_leaf") == old.function("fixed_leaf")
    assert new.function("fixed_low") == old.function("fixed_low")
    target = old.address("fixed_leaf")
    assert calls_to(new, "direct_caller", target) == [1]
    assert calls_to(new, "tail_caller", target) == [0]
    assert calls_to(new, "low_caller", old.address("fixed_low")) == [0]
    for caller in ("direct_caller", "tail_caller", "low_caller"):
        assert new.address(caller) != old.address(caller)
