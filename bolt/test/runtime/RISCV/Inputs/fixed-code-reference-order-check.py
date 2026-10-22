import struct
import sys


class ELF:
    def __init__(self, path):
        self.data = open(path, "rb").read()
        h = struct.unpack_from("<16sHHIQQQIHHHHHH", self.data)
        self.sections = [
            struct.unpack_from("<IIQQQQIIQQ", self.data, h[6] + i * h[11])
            for i in range(h[12])
        ]
        self.symbols = {}
        for section in self.sections:
            if section[1] != 2:
                continue
            strings = self.sections[section[6]][4]
            for p in range(section[4], section[4] + section[5], section[9]):
                name, _, _, index, address, size = struct.unpack_from(
                    "<IBBHQQ", self.data, p)
                begin = strings + name
                name = self.data[begin:self.data.index(b"\0", begin)].decode()
                self.symbols[name] = index, address, size

    def address(self, name):
        return self.symbols[name][1]

    def function(self, name):
        index, address, size = self.symbols[name]
        section = self.sections[index]
        offset = section[4] + address - section[3]
        return address, self.data[offset:offset + size]


def signed(value, bits):
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def address_pairs(elf, name, target):
    address, data = elf.function(name)
    pairs = 0
    offset = 0
    while offset + 4 <= len(data):
        high, = struct.unpack_from("<I", data, offset)
        if high & 0xfff == 0x517 and offset + 8 <= len(data):
            low, = struct.unpack_from("<I", data, offset + 4)
            # The original AUIPC a0 / ADDI a0,a0 remains a symbolic pair;
            # fixed code addresses must not become far-data slot loads.
            if low & 0xfffff == 0x50513:
                actual = (address + offset + signed(high & 0xfffff000, 32)
                          + signed(low >> 20, 12))
                pairs += actual == target
        offset += 4 if high & 3 == 3 else 2
    return pairs


old, early, normal, late = (ELF(path) for path in sys.argv[1:])
names = ["main", "high_user", "tie_user", "padding", "low_user",
         "secondary_user", "negative_user", "late_user", "tiny", "atomic"]
assert len(old.function("main")[1]) < 128
assert sorted(names, key=normal.address) == names
fixed_users = ["tie_user", "low_user", "secondary_user", "negative_user",
               "high_user"]
expected = ["atomic"] + fixed_users + ["main", "padding", "late_user", "tiny"]
assert sorted(names, key=early.address) == expected

late_names = [name for name in names if name != "tiny"]
deadlines = {name: old.address(name) + 0x7ffff7ff for name in late_names}
for name in fixed_users:
    target = "fixed_high" if name == "high_user" else "fixed_low"
    deadlines[name] = min(deadlines[name], old.address(target) + 0x80000800)
deadlines["late_user"] = min(deadlines["late_user"], old.address("tiny") + 0x80000800)
ordered = [name for name in late_names if name != "atomic"]
expected_late = ["atomic"] + sorted(ordered, key=deadlines.__getitem__)
assert expected_late[1] == "late_user"
assert sorted(late_names, key=late.address) == expected_late
assert late.function("tiny") == old.function("tiny")

targets = {name: old.address("fixed_low") for name in fixed_users}
targets["secondary_user"] += 4
targets["high_user"] = old.address("fixed_high")
for new in (early, normal, late):
    for fixed in ("fixed_low", "fixed_high"):
        assert new.function(fixed) == old.function(fixed)
    for name, target in targets.items():
        assert new.address(name) != old.address(name)
        assert address_pairs(new, name, target) == 1, (name, hex(target))
    assert address_pairs(new, "late_user", new.address("tiny")) == 1
