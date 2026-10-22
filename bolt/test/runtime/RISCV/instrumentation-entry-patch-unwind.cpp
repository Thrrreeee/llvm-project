// REQUIRES: system-linux,bolt-runtime

// Place emitted code within CALL range of the original entry patches. Padding
// after hot code puts their new FDEs more than 2 GiB above the original PCs.
// A pcrel sdata4 initial location silently wraps to original PC + 4 GiB and
// prevents constructing the combined old/new EH search table.
// RUN: %clangxx %cxxflags -O1 -g -fno-omit-frame-pointer -fno-optimize-sibling-calls \
// RUN:   -fPIE -pie -fuse-ld=lld -Wl,-q,-z,norelro,--image-base=0x10000 %s -o %t.exe
// RUN: %t.exe | FileCheck %s
// RUN: llvm-bolt %t.exe --instrument --force-patch --skip-funcs=old_bridge \
// RUN:   --instrumentation-file=%t.default.fdata -o %t.default.instr
// RUN: %python %S/Inputs/far-data-unwind-check.py %t.exe %t.default.instr \
// RUN:   old_bridge new_middle --default-fde32 | FileCheck %s --check-prefix=DEFAULT
// RUN: rm -f %t.default.fdata
// RUN: %t.default.instr | FileCheck %s
// RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.default.fdata
// RUN: llvm-bolt %t.exe --instrument --riscv-instrumentation-far-data \
// RUN:   --force-patch --skip-funcs=old_bridge --custom-allocation-vma=0x7fe00000 \
// RUN:   --instrumentation-file=%t.fdata -o %t.instr
// RUN: %python %S/Inputs/far-data-unwind-check.py %t.exe %t.instr \
// RUN:   old_bridge new_middle --entry-patch-fde64 | FileCheck %s --check-prefix=PATCH
// RUN: rm -f %t.fdata
// RUN: %t.instr | FileCheck %s
// RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata

// CHECK: caught=39 cleanup=3 result=42
// DEFAULT: default FDE encoding remains pcrel sdata4
// PATCH: named entry patch FDEs use sdata8 and retain original PCs and extents
// PATCH: old EH bytes preserved; old and new FDEs indexed
// PROFILE: new_middle

#include "far-data-unwind.cpp"
