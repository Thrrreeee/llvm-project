# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## Functions whose LR/SC code cannot gain a GOT load must precede other code.
## Preserve the existing order within both groups, including user ordering.
# RUN: split-file %s %t.dir
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+c -filetype=obj %t.dir/input.s -o %t.o
# RUN: ld.lld --no-relax --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=finish --fini=finish %t.o -o %t
# RUN: llvm-bolt %t --instrument --riscv-instrumentation-far-data \
# RUN:   --generate-function-order=%t.default.order -o %t.default 2>&1 \
# RUN:   | FileCheck %s --check-prefix=DEFAULT --implicit-check-not="changes the requested function order"
# RUN: llvm-nm -n --defined-only %t.default > %t.default.nm
# RUN: %python %t.dir/check.py default %t.default.order %t.default.nm

# RUN: llvm-bolt %t --instrument --riscv-instrumentation-far-data \
# RUN:   --function-order=%t.dir/user.order --generate-function-order=%t.user.order -o %t.user \
# RUN:   2>&1 | FileCheck %s --check-prefix=USER --implicit-check-not="can't find function"
# RUN: llvm-nm -n --defined-only %t.user > %t.user.nm
# RUN: %python %t.dir/check.py user %t.user.order %t.user.nm

## Without the far-data option, explicit function ordering remains unchanged.
# RUN: llvm-bolt %t --instrument --function-order=%t.dir/user.order \
# RUN:   --generate-function-order=%t.off.order -o %t.off
# RUN: llvm-nm -n --defined-only %t.off > %t.off.nm
# RUN: %python %t.dir/check.py off %t.off.order %t.off.nm

# DEFAULT: RISC-V far-data placement: 2 functions placed before remaining emitted functions
# USER-DAG: RISC-V far-data placement: 2 functions placed before remaining emitted functions
# USER-DAG: RISC-V far-data placement changes the requested function order to satisfy fixed-reference placement priorities

#--- input.s
  .attribute arch, "rv64iac"
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  call finish
  li a0, 0
  li a7, 93
  ecall
  .size _start, .-_start

  .globl plain_a
  .type plain_a,@function
plain_a:
  li a0, 1
  ret
  .size plain_a, .-plain_a

  .globl atomic_a
  .type atomic_a,@function
atomic_a:
  lr.d a1, (a0)
  sc.d a2, a1, (a0)
  ret
  .size atomic_a, .-atomic_a

  .globl plain_b
  .type plain_b,@function
plain_b:
  li a0, 2
  ret
  .size plain_b, .-plain_b

  .globl atomic_b
  .type atomic_b,@function
atomic_b:
  lr.w a1, (a0)
  sc.w a2, a1, (a0)
  ret
  .size atomic_b, .-atomic_b

  .globl finish
  .type finish,@function
finish:
  ret
  .size finish, .-finish

## Keep an existing dynamic RELATIVE relocation for the far-data mode.
  .data
  .p2align 3
data:
  .quad data

#--- user.order
plain_b
atomic_b
_start
atomic_a
plain_a
finish
#--- check.py
import sys

expected = {
    "default": ["atomic_a", "atomic_b", "_start", "plain_a", "plain_b", "finish"],
    "user": ["atomic_b", "atomic_a", "plain_b", "_start", "plain_a", "finish"],
    "off": ["plain_b", "atomic_b", "_start", "atomic_a", "plain_a", "finish"],
}[sys.argv[1]]
with open(sys.argv[2]) as stream:
    assert stream.read().splitlines() == expected
with open(sys.argv[3]) as stream:
    actual = [fields[-1] for line in stream
              if len(fields := line.split()) == 3 and fields[-1] in expected]
assert actual == expected, actual
