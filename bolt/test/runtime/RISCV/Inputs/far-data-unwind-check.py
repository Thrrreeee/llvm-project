"""Check old EH bytes and resolve both sides of the emitted EH search table."""

import mmap
import struct
import sys


class ELF:
    def __init__(self, path):
        self.file = open(path, "rb")
        self.data = mmap.mmap(self.file.fileno(), 0, access=mmap.ACCESS_READ)
        h = struct.unpack_from("<16sHHIQQQIHHHHHH", self.data)
        self.programs = [
            struct.unpack_from("<IIQQQQQQ", self.data, h[5] + i * h[9])
            for i in range(h[10])
        ]
        sections = [
            struct.unpack_from("<IIQQQQIIQQ", self.data, h[6] + i * h[11])
            for i in range(h[12])
        ]
        strings = sections[h[13]][4]
        self.sections = {self.string(strings + s[0]): s for s in sections}
        self.symbols = {}
        for s in sections:
            if s[1] != 2:
                continue
            strings = sections[s[6]][4]
            for off in range(s[4], s[4] + s[5], s[9]):
                n, _, _, _, value, size = struct.unpack_from("<IBBHQQ", self.data, off)
                self.symbols[self.string(strings + n)] = (value, size)

    def string(self, off):
        return self.data[off : self.data.find(b"\0", off)].decode()

    def bytes_at(self, address, size):
        for s in self.sections.values():
            if s[1] != 8 and s[2] & 2 and s[3] <= address and address + size <= s[3] + s[5]:
                off = s[4] + address - s[3]
                return self.data[off : off + size]
        raise AssertionError(("unmapped address", hex(address), size))

    def header(self):
        s = self.sections[".eh_frame_hdr"]
        data = self.data[s[4] : s[4] + s[5]]
        assert data[0] == 1 and data[2] == 3
        assert (data[1], data[3]) in ((0x1B, 0x3B), (0x1C, 0x3C))
        size = 8 if data[3] == 0x3C else 4
        fmt = "<q" if size == 8 else "<i"
        frame = s[3] + 4 + struct.unpack_from(fmt, data, 4)[0]
        count = struct.unpack_from("<I", data, 4 + size)[0]
        table = {}
        previous = -1
        for i in range(count):
            off = 8 + size + 2 * size * i
            pc = s[3] + struct.unpack_from(fmt, data, off)[0]
            fde = s[3] + struct.unpack_from(fmt, data, off + size)[0]
            assert pc > previous
            previous = pc
            table[pc] = fde
        return frame, table, size

    def frame(self, fde, details=False):
        # Decode the CIE's R augmentation, then the FDE initial location.
        length, delta = struct.unpack("<II", self.bytes_at(fde, 8))
        cie = Cursor(self, fde + 4 - delta + 8)
        version = cie.byte()
        augmentation = []
        while True:
            ch = cie.byte()
            if not ch:
                break
            augmentation.append(chr(ch))
        if version == 4:
            assert cie.byte() == 8 and cie.byte() == 0
        cie.leb()
        cie.leb()
        cie.byte() if version == 1 else cie.leb()
        encoding = 0
        lsda_encoding = 0xFF
        personality = None
        for ch in augmentation:
            if ch == "z":
                cie.leb()
            elif ch == "R":
                encoding = cie.byte()
            elif ch == "L":
                lsda_encoding = cie.byte()
            elif ch == "P":
                personality_encoding = cie.byte()
                personality_field = cie.address
                personality = (personality_encoding, personality_field,
                               cie.encoded(personality_encoding))
            else:
                raise AssertionError(("unexpected CIE augmentation", ch))
        cursor = Cursor(self, fde + 8)
        pc = cursor.encoded(encoding)
        extent = cursor.encoded(encoding & 15)
        lsda = None
        if augmentation and augmentation[0] == "z":
            cursor.leb()
            if lsda_encoding != 0xFF:
                lsda = cursor.encoded(lsda_encoding)
        if details:
            return pc, personality, lsda, encoding, extent
        return pc, personality, lsda


class Cursor:
    def __init__(self, elf, address):
        self.elf, self.address = elf, address

    def byte(self):
        value = self.elf.bytes_at(self.address, 1)[0]
        self.address += 1
        return value

    def leb(self):
        value, shift = 0, 0
        while True:
            byte = self.byte()
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
            shift += 7

    def encoded(self, encoding):
        address = self.address
        fmt = {0: "<Q", 3: "<I", 4: "<Q", 11: "<i", 12: "<q"}[encoding & 15]
        size = struct.calcsize(fmt)
        value = struct.unpack(fmt, self.elf.bytes_at(address, size))[0]
        self.address += size
        modifier = encoding & 0x70
        assert modifier in (0, 0x10)
        return value + (address if value and modifier == 0x10 else 0)


old, new = (ELF(path) for path in sys.argv[1:3])
old_name, new_name = sys.argv[3:5]
if "--default-fde32" in sys.argv:
    _, table, _ = new.header()
    assert table
    for fde in table.values():
        assert new.frame(fde, details=True)[3] == 0x1B
    assert any(name.endswith(".org.0") for name in new.symbols)
    print("default FDE encoding remains pcrel sdata4")
    sys.exit(0)
old_eh = old.sections[".eh_frame"]
original_bytes = old.bytes_at(old_eh[3], old_eh[5])
assert new.bytes_at(old_eh[3], old_eh[5]) == original_bytes
old_frame, old_table, _ = old.header()
new_frame, new_table, width = new.header()
old_pc = old.symbols[old_name][0]
new_pc = new.symbols[new_name][0]
assert new.symbols[old_name][0] == old_pc
assert new_pc != old.symbols[new_name][0]
assert new_table[old_pc] == old_table[old_pc]
assert old_eh[3] <= new_table[old_pc] < old_eh[3] + old_eh[5]
assert new_frame != old_frame
assert new_frame <= new_table[new_pc]
# All indexed FDEs must point into an allocated section, not a wrapped address.
for pc, fde in new_table.items():
    length, cie_delta = struct.unpack("<II", new.bytes_at(fde, 8))
    assert length >= 8 and cie_delta
    assert new.bytes_at(fde + 4 - cie_delta + 4, 4) == b"\0" * 4
    decoded_pc, personality, lsda = new.frame(fde)
    assert decoded_pc == pc, (hex(pc), hex(fde), hex(decoded_pc))
    if personality and personality[2]:
        new.bytes_at(personality[2], 8)
    if lsda:
        new.bytes_at(lsda, 1)
if "--far" in sys.argv:
    assert new_pc - old_pc > (1 << 31)
if "--far" in sys.argv or "--wide-span" in sys.argv:
    assert new_frame - old_eh[3] > (1 << 31)
    assert width == 4
header = new.sections[".eh_frame_hdr"]
assert any(p[0] == 0x6474E550 and p[2] == header[4] and p[3] == header[3]
           and p[5] == header[5] for p in new.programs)
loads = [p for p in new.programs if p[0] == 1]
assert [p[3] for p in loads] == sorted(p[3] for p in loads)
for fde in new_table.values():
    assert any(p[3] <= fde and fde + 8 <= p[3] + p[5] for p in loads)
if "--prefix-header" in sys.argv:
    assert old.sections[".text"][3] < header[3] < new.sections[".text"][3]
if "--hole-header" in sys.argv:
    assert header[3] < new.sections[".text"][3]
    assert any(p[0] == 1 and p[1] == 4 and p[3] <= header[3]
               and header[3] + header[5] <= p[3] + p[5]
               for p in new.programs)
    for p in old.programs:
        if p[0] == 1:
            assert header[3] + header[5] <= p[3] or p[3] + p[6] <= header[3]
if "--exception-targets" in sys.argv:
    _, personality, lsda = new.frame(new_table[new_pc])
    encoding, field, target = personality
    assert encoding == 0x9C
    assert target == old.symbols["personality_slot"][0], hex(target)
    assert field - target > (1 << 31)
    assert lsda is not None
    cursor = Cursor(new, lsda)
    lp_encoding = cursor.byte()
    if lp_encoding != 0xFF:
        cursor.encoded(lp_encoding)
    tt_encoding = cursor.byte()
    tt_offset = cursor.leb()
    tt_end = cursor.address + tt_offset
    assert tt_encoding == 0x9C
    tt_field = tt_end - 8  # This fixture has exactly one type table entry.
    tt_target = Cursor(new, tt_field).encoded(tt_encoding)
    assert tt_target == old.symbols["typeinfo_slot"][0], hex(tt_target)
    assert tt_field - tt_target > (1 << 31)
    assert new.bytes_at(target, 8) == old.bytes_at(target, 8)
    assert new.bytes_at(tt_target, 8) == old.bytes_at(tt_target, 8)
    print("far personality and typeinfo resolve to original slots")
if "--entry-patch-fde64" in sys.argv:
    assert width == 4
    assert old.frame(old_table[old_pc], details=True)[3] == 0x1B
    patches = [(name, value, size) for name, (value, size) in new.symbols.items()
               if name.endswith(".org.0")]
    assert patches
    checked_new_entry = False
    for name, source, size in patches:
        original_name = name[:-len(".org.0")]
        assert source == old.symbols[original_name][0], name
        fde = new_table[source]
        assert fde >= new_frame
        pc, _, _, encoding, extent = new.frame(fde, details=True)
        assert encoding == 0x1C, (name, hex(encoding))
        assert pc == source and extent == size == 8, (name, pc, extent, size)
        assert fde + 8 - source > 1 << 31, (name, hex(fde), hex(source))
        # The entry patch itself must remain within AUIPC/JALR range. Decode
        # it independently so a too-distant call cannot mask the FDE case.
        high, low = struct.unpack("<II", new.bytes_at(source, 8))
        assert high & 0xFFF == 0x317  # auipc t1
        assert low & 0xFFFFF == 0x30067  # jalr zero, t1
        upper = struct.unpack("<i", struct.pack("<I", high & 0xFFFFF000))[0]
        lower = struct.unpack("<i", struct.pack("<I", low))[0] >> 20
        target = source + upper + lower
        assert target == new.symbols[original_name][0], (name, hex(target))
        checked_new_entry |= original_name == new_name
    assert checked_new_entry
    for fde in new_table.values():
        if fde >= new_frame:
            assert new.frame(fde, details=True)[3] == 0x1C
    print("named entry patch FDEs use sdata8 and retain original PCs and extents")
print("old EH bytes preserved; old and new FDEs indexed")
