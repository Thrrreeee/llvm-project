# REQUIRES: system-linux,bolt-runtime,target=riscv64{{.*}}

## The report sees the instrumented sizes and fixed-data windows without
## changing layout. The exported order must round-trip exact local /N names.
# RUN: split-file %s %t.dir
# RUN: llvm-mc -triple=riscv64 -mattr=+a,+c -filetype=obj %t.dir/input.s -o %t.o
# RUN: ld.lld --emit-relocs -pie -e _start --dynamic-linker=ld.so --init=early --fini=early %t.o -o %t
# RUN: llvm-bolt %t --instrument -o %t.baseline
# RUN: llvm-bolt %t --instrument --riscv-instrumentation-layout-report=%t.jsonl \
# RUN:   --riscv-instrumentation-order-file=%t.order -o %t.reported
# RUN: llvm-nm -n %t.baseline > %t.baseline.nm
# RUN: llvm-nm -n %t.reported > %t.reported.nm
# RUN: diff %t.baseline.nm %t.reported.nm
# RUN: %python %t.dir/check.py %t.jsonl %t.order
# RUN: llvm-bolt %t --instrument --function-order=%t.order -v=1 -o %t.ordered \
# RUN:   2>&1 | FileCheck %s --check-prefix=ORDER --implicit-check-not="can't find function"
# RUN: llvm-nm -n %t.ordered | FileCheck %s --check-prefix=SYMBOLS
# RUN: not llvm-bolt %t --riscv-instrumentation-layout-report=%t.invalid -o %t.out \
# RUN:   2>&1 | FileCheck %s --check-prefix=REQUIRES-INSTR
# RUN: not llvm-bolt %t --instrument --riscv-instrumentation-order-file=%t.invalid -o %t.out \
# RUN:   2>&1 | FileCheck %s --check-prefix=REQUIRES-REPORT
# RUN: not llvm-bolt %t --instrument --custom-allocation-vma=0x90000000 \
# RUN:   --riscv-instrumentation-layout-report=%t.far.jsonl -o %t.far \
# RUN:   2>&1 | FileCheck %s --check-prefix=FAR
# RUN: %python %t.dir/check.py %t.far.jsonl far

# ORDER: --function-order specified without --reorder-functions, defaulting to --reorder-functions=user
# SYMBOLS: {{[0-9a-f]+}} T early
# SYMBOLS: {{[0-9a-f]+}} t local
# SYMBOLS: {{[0-9a-f]+}} T _start
# REQUIRES-INSTR: --riscv-instrumentation-layout-report requires RISC-V64 --instrument
# REQUIRES-REPORT: --riscv-instrumentation-order-file requires --riscv-instrumentation-layout-report
# FAR: 2 candidate window violations; final linkability is not proven
# FAR: BOLT-ERROR: JITLink failed:
# FAR-SAME: is out of range of R_RISCV_PCREL_HI20

#--- input.s
  .attribute arch, "rv64iac"
  .option norelax
  .text
  .globl _start
  .type _start,@function
_start:
  call local
  call early
  li a0, 0
  li a7, 93
  ecall
  .size _start, .-_start

  .type local,@function
local:
.Lhigh:
  auipc a0, %pcrel_hi(high_data)
  ld a0, %pcrel_lo(.Lhigh)(a0)
  ret
  .size local, .-local

  .globl early
  .type early,@function
early:
.Llow:
  auipc a0, %pcrel_hi(low_data)
  ld a0, %pcrel_lo(.Llow)(a0)
.Lgot:
  auipc a1, %got_pcrel_hi(low_data)
  ld a1, %pcrel_lo(.Lgot)(a1)
  ret
  .size early, .-early

  .section .rodata,"a",@progbits
  .p2align 3
  .type low_data,@object
low_data:
  .quad 1
  .size low_data, .-low_data

  .data
  .p2align 3
  .type high_data,@object
high_data:
  .quad 2
  .size high_data, .-high_data

#--- check.py
import json
import sys

with open(sys.argv[1]) as stream:
    rows = [json.loads(line) for line in stream]
model, *functions, summary = rows
assert model["kind"] == "model"
assert model["model"] == "whole-function-fixed-data-window"
assert model["minimum_displacement"] == -2147485696
assert model["maximum_displacement"] == 2147481599
assert summary["kind"] == "summary"
assert summary["functions"] == 3
assert summary["constrained_functions"] == 2
assert summary["fixed_references"] == 3  # Direct data and the original GOT.
assert summary["unresolved_references"] > 0  # Instrumentation counters.
assert summary["unverified_order_names"] == 0
assert summary["estimated_bytes"] == sum(f["estimated_size"] for f in functions)
names = [f["name"] for f in functions]
assert names == ["early", "local/1", "_start"], names
if sys.argv[2] == "far":
    assert summary["window_violations"] == 2
    assert not summary["order_file_written"]
    assert all(f["deadline_slack"] < 0 for f in functions[:2])
else:
    assert summary["window_violations"] == 0
    assert summary["order_file_written"]
    with open(sys.argv[2]) as stream:
        assert stream.read().splitlines() == names
for rank, f in enumerate(functions):
    assert f["kind"] == "function"
    assert f["candidate_rank"] == rank
    assert f["order_name_verified"]
    assert f["estimated_size"] > f["input_size"]
    assert f["candidate_end_upper"] >= f["candidate_start_lower"] + f["estimated_size"]
    if f["fixed_references"]:
        assert f["deadline_slack"] == f["window_end_upper"] - f["candidate_end_upper"]
    else:
        assert f["window_end_upper"] is None
        assert f["deadline_slack"] is None
