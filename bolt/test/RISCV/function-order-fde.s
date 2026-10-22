# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## A local marker is registered before its FDE-only function is discovered.
## The shared BinaryData's primary symbol does not identify that function.
## Both layout export and order-file consumption must use its exact symbol.
# RUN: split-file %s %t.dir
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+c -save-temp-labels -filetype=obj %t.dir/first.s -o %t.first.o
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+c -filetype=obj %t.dir/second.s -o %t.second.o
# RUN: ld.lld --no-relax --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=fini --fini=fini %t.first.o %t.second.o -o %t
# RUN: llvm-bolt %t --instrument --riscv-instrumentation-layout-report=%t.jsonl \
# RUN:   --riscv-instrumentation-order-file=%t.order -o %t.reported
# RUN: %python %t.dir/check.py report %t.jsonl %t.order
# RUN: llvm-bolt %t --instrument --function-order=%t.order \
# RUN:   --generate-function-order=%t.roundtrip -v=1 -o %t.ordered 2>&1 \
# RUN:   | FileCheck %s --check-prefix=ORDER --implicit-check-not="can't find function"
# RUN: diff %t.order %t.roundtrip

## An unqualified local name still selects both duplicates in /N order.
# RUN: printf 'duplicate\nfini\n' > %t.local.order
# RUN: llvm-bolt %t --function-order=%t.local.order --generate-function-order=%t.local.out -o %t.local
# RUN: %python %t.dir/check.py local %t.local.out

## An existing non-function exact name must not fall back to a local function.
# RUN: printf 'shadow\nfini\n' > %t.shadow.order
# RUN: llvm-bolt %t --function-order=%t.shadow.order --generate-function-order=%t.shadow.out -v=1 -o %t.shadow \
# RUN:   2>&1 | FileCheck %s --check-prefix=SHADOW
# RUN: %python %t.dir/check.py shadow %t.shadow.out

# ORDER: --function-order specified without --reorder-functions, defaulting to --reorder-functions=user
# SHADOW: BOLT-WARNING: Reorder functions: can't find function for shadow
# SHADOW: BOLT-WARNING: Reorder functions: can't find functions for 1 entries in -function-order list

#--- first.s
  .attribute arch, "rv64iac"
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  li a0, 0
  li a7, 93
  ecall
## Leave _start's size unknown during the initial symbol scan so .Lfde is
## registered as a local label. Its function is only created from the FDE.
.Lfde:
  .cfi_startproc
.Lhi:
  auipc a0, %pcrel_hi(data)
  ld a0, %pcrel_lo(.Lhi)(a0)
  ret
  .cfi_endproc

  .globl fini
  .type fini,@function
fini:
  ret
  .size fini, .-fini

  .type duplicate,@function
duplicate:
  ret
  .size duplicate, .-duplicate

  .section .rodata,"a",@progbits
  .p2align 3
  .type data,@object
data:
  .quad 1
  .size data, .-data
  .globl shadow
  .type shadow,@object
shadow:
  .quad 2
  .size shadow, .-shadow

#--- second.s
  .attribute arch, "rv64iac"
  .text
  .type duplicate,@function
duplicate:
  ret
  .size duplicate, .-duplicate
  .type shadow,@function
shadow:
  ret
  .size shadow, .-shadow

#--- check.py
import json
import sys

if sys.argv[1] == "report":
    with open(sys.argv[2]) as stream:
        rows = [json.loads(line) for line in stream]
    functions = [row for row in rows if row["kind"] == "function"]
    summary = rows[-1]
    assert summary["functions"] == 6
    assert summary["order_file_written"]
    assert summary["unverified_order_names"] == 0
    assert all(row["order_name_verified"] for row in functions)
    names = [row["name"] for row in functions]
    assert names[0].startswith("__BOLT_FDE_FUNCat"), names
    assert names[1:] == ["_start", "fini", "duplicate/1", "duplicate/2", "shadow/1"]
    with open(sys.argv[3]) as stream:
        assert stream.read().splitlines() == names
else:
    with open(sys.argv[2]) as stream:
        names = stream.read().splitlines()
    if sys.argv[1] == "local":
        assert names[:3] == ["duplicate/1", "duplicate/2", "fini"], names
    else:
        assert names[0] == "fini", names
