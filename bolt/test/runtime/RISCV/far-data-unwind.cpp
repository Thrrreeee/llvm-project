// REQUIRES: system-linux,bolt-runtime

// Unwind across original and emitted functions, including cleanup landing pads
// in both frame areas. A successful startup alone does not exercise these FDEs.
// RUN: %clangxx %cxxflags -O1 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls \
// RUN:   -fPIE -pie -Wl,-q %s -o %t.exe
// RUN: %t.exe | FileCheck %s
// RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
// RUN:   --skip-funcs=old_bridge --instrumentation-file=%t.fdata -o %t.instr
// RUN: %python %S/Inputs/far-data-unwind-check.py %t.exe %t.instr old_bridge new_middle
// RUN: rm -f %t.fdata
// RUN: %t.instr | FileCheck %s
// RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
// RUN: llvm-bolt %t.exe --data=%t.fdata --reorder-blocks=cache -o %t.bolt
// RUN: %t.bolt | FileCheck %s
// Place old code within call range of new code, but old EH more than 2 GiB
// below new EH. The table must remain datarel32 for libgcc's binary search;
// datarel64 falls back to scanning just the new, disjoint .eh_frame area.
// The image base keeps the output compact despite the high virtual addresses.
// RUN: %clangxx %cxxflags -O1 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls \
// RUN:   -fPIE -pie -fuse-ld=lld -Wl,-q,-z,norelro,--image-base=0x1ffff000 \
// RUN:   -Wl,--section-start=.text=0x90000000,--section-start=.plt=0x90010000 \
// RUN:   -Wl,--section-start=.rodata=0x90020000,--section-start=.eh_frame=0x20000000 \
// RUN:   -Wl,--section-start=.eh_frame_hdr=0x20010000,--section-start=.gcc_except_table=0x20020000 \
// RUN:   -Wl,--section-start=.data.rel.ro=0x90028000,--section-start=.data=0x90030000 \
// RUN:   -Wl,--section-start=.got=0x90040000,--section-start=.sdata=0x90040800 \
// RUN:   -Wl,--section-start=.bss=0x90050000 '-Wl,--defsym=__global_pointer$=0x90041000' \
// RUN:   %s -o %t.high.exe
// RUN: %t.high.exe | FileCheck %s
// RUN: llvm-bolt %t.high.exe --instrument --riscv-instrumentation-far-data \
// RUN:   --skip-funcs=old_bridge --custom-allocation-vma=0x100000000 \
// RUN:   --instrumentation-file=%t.high.fdata -o %t.high.instr
// RUN: %python %S/Inputs/far-data-unwind-check.py %t.high.exe %t.high.instr old_bridge new_middle --wide-span --hole-header
// RUN: rm -f %t.high.fdata
// RUN: %t.high.instr | FileCheck %s
// RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.high.fdata
// Here the old/new EH span also exceeds 2 GiB, but the reserved prefix is in
// range of both frame areas, so no separate load segment is necessary.
// RUN: %clangxx %cxxflags -O1 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls \
// RUN:   -fPIE -pie -fuse-ld=lld -Wl,-q,-z,norelro,--image-base=0x1000f000 \
// RUN:   -Wl,--section-start=.text=0x70000000,--section-start=.plt=0x70010000 \
// RUN:   -Wl,--section-start=.rodata=0x70020000,--section-start=.eh_frame=0x10010000 \
// RUN:   -Wl,--section-start=.eh_frame_hdr=0x10020000,--section-start=.gcc_except_table=0x10030000 \
// RUN:   -Wl,--section-start=.data.rel.ro=0x70028000,--section-start=.data=0x70030000 \
// RUN:   -Wl,--section-start=.got=0x70040000,--section-start=.sdata=0x70040800 \
// RUN:   -Wl,--section-start=.bss=0x70050000 '-Wl,--defsym=__global_pointer$=0x70041000' \
// RUN:   %s -o %t.prefix.exe
// RUN: %t.prefix.exe | FileCheck %s
// RUN: llvm-bolt %t.prefix.exe --instrument --riscv-instrumentation-far-data \
// RUN:   --skip-funcs=old_bridge --custom-allocation-vma=0x90000000 \
// RUN:   --instrumentation-file=%t.prefix.fdata -o %t.prefix.instr
// RUN: %python %S/Inputs/far-data-unwind-check.py %t.prefix.exe %t.prefix.instr old_bridge new_middle --wide-span --prefix-header
// RUN: rm -f %t.prefix.fdata
// RUN: %t.prefix.instr | FileCheck %s
// RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.prefix.fdata

// CHECK: caught=39 cleanup=3 result=42
// PROFILE: new_middle

#include <cstdio>

static volatile int Cleanups;

struct Payload {
  int Value;
};

struct Guard {
  int Value;
  __attribute__((noinline)) ~Guard() { Cleanups = Cleanups + Value; }
};

extern "C" __attribute__((noinline)) void new_thrower() {
  throw Payload{39};
}

extern "C" __attribute__((noinline)) void old_bridge() {
  Guard G{1};
  new_thrower();
}

extern "C" __attribute__((noinline)) void new_middle() {
  Guard G{2};
  old_bridge();
}

int main() {
  try {
    new_middle();
  } catch (const Payload &P) {
    std::printf("caught=%d cleanup=%d result=%d\n", P.Value, int(Cleanups),
                P.Value + int(Cleanups));
    return P.Value != 39 || Cleanups != 3;
  }
  return 1;
}
