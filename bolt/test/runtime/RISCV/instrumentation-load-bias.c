/*
REQUIRES: system-linux,bolt-runtime

The runtime must subtract the PIE load bias to resolve indirect-call targets.
Exercise ordinary placement and link-time addresses above 4 GiB. Keeping the
input's PLT near the high output avoids an unrelated far-call limitation.

RUN: %clang %cflags -O1 -fno-optimize-sibling-calls -fPIE -pie -Wl,-q %s -o %t.exe
RUN: %t.exe
RUN: llvm-bolt %t.exe --instrument --instrumentation-file=%t.fdata -o %t.instr
RUN: rm -f %t.fdata
RUN: %t.instr
RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.fdata
RUN: llvm-bolt %t.exe --data=%t.fdata --print-only=invoke --print-finalized \
RUN:   -o %t.opt | FileCheck %s --check-prefix=CALL
RUN: %t.opt

RUN: %clang %cflags -O1 -fno-optimize-sibling-calls -fPIE -pie -fuse-ld=lld \
RUN:   -Wl,-q,--image-base=0x90000000 %s -o %t.high.exe
RUN: %t.high.exe
RUN: llvm-bolt %t.high.exe --instrument --custom-allocation-vma=0x100000000 \
RUN:   --instrumentation-file=%t.high.fdata -o %t.high.instr
RUN: rm -f %t.high.fdata
RUN: %t.high.instr
RUN: FileCheck %s --check-prefix=PROFILE --input-file=%t.high.fdata
RUN: llvm-bolt %t.high.exe --data=%t.high.fdata --print-only=invoke --print-finalized \
RUN:   -o %t.high.opt | FileCheck %s --check-prefix=CALL
RUN: %t.high.opt

PROFILE: invoke {{[0-9a-f]+}} 1 increment 0 0 1
CALL: CallProfile: 1 (0 misses)
CALL-NEXT: { increment: 1 (0 misses) }
*/

__attribute__((noinline)) int increment(int Value) { return Value + 1; }

__attribute__((noinline)) int invoke(int (*Function)(int), int Value) {
  return Function(Value);
}

int main(void) {
  int (*volatile Function)(int) = increment;
  return invoke(Function, 41) != 42;
}
