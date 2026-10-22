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
                name, _, _, _, address, size = struct.unpack_from(
                    "<IBBHQQ", self.data, offset
                )
                begin = strings + name
                name = self.data[begin:self.data.index(b"\0", begin)].decode()
                self.symbols[name] = (address, size)

    def contents(self, address, size):
        for section in self.sections:
            if (section[1] != 8 and section[3] <= address
                    and address + size <= section[3] + section[5]):
                offset = section[4] + address - section[3]
                return self.data[offset:offset + size]
        raise AssertionError(hex(address))

    def word(self, address):
        return struct.unpack("<I", self.contents(address, 4))[0]

    def entry(self, address, index):
        return address + signed(self.word(address + 4 * index), 32)


def signed(value, bits):
    return (value ^ (1 << (bits - 1))) - (1 << (bits - 1))


def table_address(elf, function):
    address, size = elf.symbols[function]
    end = address + size
    while address < end:
        high = elf.word(address)
        if high & 0xfff == 0x717:  # AUIPC a4
            low = elf.word(address + 4)
            assert low & 0x707f == 0x13
            assert (low >> 7) & 31 == 14 and (low >> 15) & 31 == 14
            return address + signed(high & 0xfffff000, 32) + signed(low >> 20, 12)
        address += 4 if high & 3 == 3 else 2
    raise AssertionError(function)


plain_old, plain_new, internal_old, internal_new = (
    ELF(path) for path in sys.argv[1:]
)
for old in (plain_old, internal_old):
    table = old.symbols["PIC_JT"][0]
    assert table_address(old, "dispatch") == table
    assert table_address(old, "dispatch.cold.1") == table
    assert old.entry(table, 0) == old.symbols[".Lhotcase"][0]
    assert old.entry(table, 1) == old.symbols[".Lcoldcase"][0]

# Without an internal call, both fragments and their shared table move.
for function in ("dispatch", "dispatch.cold.1"):
    assert plain_new.symbols[function][0] != plain_old.symbols[function][0]
plain_table = table_address(plain_new, "dispatch")
assert plain_table != plain_old.symbols["PIC_JT"][0]
assert table_address(plain_new, "dispatch.cold.1") == plain_table
for index, label in enumerate((".Lhotcase", ".Lcoldcase")):
    assert plain_new.entry(plain_table, index) == plain_new.symbols[label][0]

# With an internal call, the original hot body is retained byte-for-byte.
hot_address, hot_size = internal_old.symbols["dispatch"]
assert internal_new.symbols["dispatch"] == (hot_address, hot_size)
assert (internal_new.contents(hot_address, hot_size)
        == internal_old.contents(hot_address, hot_size))
assert internal_new.symbols[".Lhotcase"] == internal_old.symbols[".Lhotcase"]

# Both dispatches continue to use the original table. Its first entry stays
# fixed, while its second entry must refer to the newly emitted cold fragment.
table = internal_old.symbols["PIC_JT"][0]
assert internal_new.symbols["PIC_JT"][0] == table
for function in ("dispatch", "dispatch.cold.1"):
    assert table_address(internal_new, function) == table
assert internal_new.entry(table, 0) == internal_old.entry(table, 0)
cold_address, cold_size = internal_new.symbols["dispatch.cold.1"]
assert cold_address != internal_old.symbols["dispatch.cold.1"][0]
cold_target = internal_new.entry(table, 1)
assert cold_target == internal_new.symbols[".Lcoldcase"][0]
assert cold_target != internal_old.entry(table, 1)
assert cold_address < cold_target < cold_address + cold_size

for old, new in ((plain_old, plain_new), (internal_old, internal_new)):
    old_address, old_size = old.symbols["body_callee"]
    new_address, new_size = new.symbols["body_callee"]
    assert new_address != old_address
    assert new_size > old_size
