## Check that BOLT recognizes a non-preemptible IFUNC IPLT entry and tracks
## the resolver when the linker canonicalizes the IFUNC symbol to the entry.

# RUN: llvm-mc -filetype=obj -triple=riscv64 -mattr=+relax -o %t.o %s
# RUN: ld.lld -pie -q -o %t.exe %t.o
# RUN: llvm-bolt %t.exe -o %t.bolt --print-disasm --print-only=_start 2>&1 \
# RUN:   | FileCheck --check-prefix=BOLT %s
# RUN: llvm-readelf -r -s %t.bolt | FileCheck --check-prefix=ELF %s

# BOLT: Binary Function "_start
# BOLT: auipc a0, %pcrel_hi(__BOLT_PSEUDO_.iplt)
# BOLT-NOT: unable to get new address corresponding to input address
# ELF: R_RISCV_IRELATIVE
# ELF: FUNC{{.*}}ifunc0

  .text
  .globl _start
  .type _start, @function
_start:
1:
  auipc a0, %pcrel_hi(ifunc0)
  addi a0, a0, %pcrel_lo(1b)

  .globl func
  .type func, @function
func:
  ret

  .globl ifunc0
  .type ifunc0, @gnu_indirect_function
ifunc0:
  ret
