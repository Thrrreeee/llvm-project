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
        for s in self.sections:
            if s[1] != 2:
                continue
            strings = self.sections[s[6]][4]
            for p in range(s[4], s[4] + s[5], s[9]):
                name, _, _, index, address, size = struct.unpack_from(
                    "<IBBHQQ", self.data, p)
                begin = strings + name
                name = self.data[begin:self.data.index(b"\0", begin)].decode()
                self.symbols[name] = (index, address, size)

    def address(self, name):
        return self.symbols[name][1]

    def at(self, address, size):
        for s in self.sections:
            if s[1] != 8 and s[2] & 2 and s[3] <= address and address + size <= s[3] + s[5]:
                offset = s[4] + address - s[3]
                return self.data[offset:offset + size]
        raise AssertionError("unmapped address")


def signed(value, bits):
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def decode(pc, high, low):
    assert high & 0x7f == 0x17
    assert low & 0x707f == 0x67
    assert (high >> 7) & 31 == (low >> 15) & 31
    return (pc + signed(high & 0xfffff000, 32) + signed(low >> 20, 12)) & ~1


old, early, normal = (ELF(path) for path in sys.argv[1:])
prefix = ["atomic_second", "atomic_first"]
ordinary = ["main", "entry_late", "back_caller", "late_caller", "padding", "entry_early"]
names = ordinary + prefix
assert sorted(names, key=normal.address) == names

# Explicitly compare the two CALL bounds. Using one shared +/-2GiB constant
# would lose the AUIPC rounding asymmetry and misorder near-equal limits.
deadlines = {name: old.address(name) + 0x7ffff7ff for name in ordinary}
deadlines["late_caller"] = min(deadlines["late_caller"], old.address("tiny") + 0x80000800)
deadlines["back_caller"] = min(deadlines["back_caller"], old.address("fixed_leaf") + 0x80000800)
expected = prefix + sorted(ordinary, key=deadlines.__getitem__)
assert expected == prefix + ["late_caller", "entry_early", "back_caller", "padding", "entry_late", "main"]
assert sorted(names, key=early.address) == expected
assert old.address("secondary_entry") == old.address("entry_early") + 8
assert deadlines["entry_early"] < deadlines["back_caller"] < old.address("secondary_entry") + 0x7ffff7ff

for new in (early, normal):
    # The rejected tiny function remains byte-for-byte at its old address.
    assert new.address("tiny") == old.address("tiny")
    assert old.symbols["tiny"][2] == 4
    assert new.at(old.address("tiny"), 4) == old.at(old.address("tiny"), 4)
    assert new.address("entry_alias") == new.address("entry_early")
    for name in names + ["secondary_entry"]:
        pc = old.address(name)
        high, low = struct.unpack("<II", new.at(pc, 8))
        assert (high >> 7) & 31 == 6  # t1, the long-tail-call scratch register
        assert (low >> 7) & 31 == 0   # tail call preserves ra
        assert decode(pc, high, low) == new.address(name)
        assert new.address(name) != pc

    # The caller whose target became fixed during PatchEntries still reaches it.
    pc = new.address("late_caller")
    data = new.at(pc, new.symbols["late_caller"][2])
    found = 0
    for offset in range(0, len(data) - 7, 2):
        high, low = struct.unpack_from("<II", data, offset)
        if (high & 0x7f == 0x17 and low & 0x707f == 0x67
                and (high >> 7) & 31 == (low >> 15) & 31
                and decode(pc + offset, high, low) == old.address("tiny")):
            assert (low >> 7) & 31 == 0
            found += 1
    assert found == 1
