## Reuse one input to test ignored references, transitive entry patching, and
## moving linker symbols. source retains middle and its address-taken leaf,
## while the independent call pair in middle can follow a moved target entry.
# RUN: llvm-mc -triple=riscv64 -filetype=obj %s -o %t.o
# RUN: ld.lld --emit-relocs --no-relax -Ttext=0x10000 -e source %t.o -o %t.exe

# RUN: llvm-bolt %t.exe --skip-funcs=source --print-cfg --print-only=end_refs -o %t.skip | FileCheck %s --check-prefix=END
# RUN: llvm-objdump -d %t.skip | FileCheck %s --check-prefixes=KEEP,MOVED
# RUN: llvm-bolt %t.exe --force-patch -o %t.patch 2>&1 | FileCheck %s --check-prefix=PATCH
# RUN: llvm-objdump -d %t.patch | FileCheck %s --check-prefixes=KEEP,PINNED
# RUN: not llvm-bolt %t.exe --skip-funcs=end_refs -o %t.end 2>&1 | FileCheck %s --check-prefix=ERROR

## Check original addresses and instructions, so an entry trampoline cannot
## hide a moved target or overwrite a function retained later in the pass.
# KEEP-LABEL: 0000000000010000 <leaf>:
# KEEP-NEXT: {{.*}} nop
# KEEP-LABEL: 000000000001000c <middle>:
# KEEP-NEXT: {{.*}} auipc ra,
## Preserve the fixed call's base/link registers and reach the secondary entry.
# MOVED: 1002c: {{.*}} auipc t0, 0x3f0
# MOVED-NEXT: 10030: {{.*}} jalr t0, -0x28(t0) <target+0x4>
## Forced patching retains target because its entries are only four bytes apart.
# PINNED-LABEL: 0000000000010038 <target>:
# PINNED-NEXT: {{.*}} addi a0, a0, 0x64
# KEEP-LABEL: 0000000000010044 <source>:
# KEEP-NEXT: {{.*}} jal t0, 0x1000c <middle>
# MOVED-LABEL: 0000000000400000 <target>:
# MOVED-NEXT: {{.*}} addi a0, a0, 0x64
# MOVED-NEXT: 400004: {{.*}} addi a0, a0, 0x1
# PATCH: BOLT-WARNING: failed to patch entries in source

## _end coincides with end_refs' end, but must keep its own symbol identity.
# END: auipc a1, %pcrel_hi(_end)
# ERROR: BOLT-ERROR: cannot update RISC-V instruction reference to _end at address 0x{{[0-9a-f]+}} in ignored function end_refs

  .option norvc
  .text
  .globl leaf, middle, target, source, end_refs
  .type leaf, @function
leaf:
  nop
  nop
  jr t0
  .size leaf, .-leaf

  .type middle, @function
middle:
  call leaf
  lla a1, leaf+4
  lui a1, %hi(leaf+8)
  addi a1, a1, %lo(leaf+8)
  beq a0, a1, leaf
## No relocation describes this pair; JALR clears bit zero to reach target+4.
  auipc t0, 0
  jalr t0, 17(t0)
  ret
  .size middle, .-middle

  .type target, @function
target:
  addi a0, a0, 100
  addi a0, a0, 1
  jr t0
  .size target, .-target

## Four bytes cannot hold an entry trampoline. Visit source after its targets
## to exercise cancelling their patches when source is retained.
  .type source, @function
source:
  jal t0, middle
  .size source, .-source

  .type end_refs, @function
end_refs:
  lla a1, _end
  lui a1, %hi(_end)
  addi a1, a1, %lo(_end)
  ret
  .size end_refs, .-end_refs
