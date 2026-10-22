//===- bolt/Passes/RISCVInstrumentationFarData.h ----------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef BOLT_PASSES_RISCVINSTRUMENTATIONFARDATA_H
#define BOLT_PASSES_RISCVINSTRUMENTATIONFARDATA_H

#include "bolt/Passes/BinaryPasses.h"

namespace llvm {
namespace bolt {

/// Materialize original fixed-data AUIPC bases through runtime-relocated slots.
class RISCVInstrumentationFarData : public BinaryFunctionPass {
public:
  RISCVInstrumentationFarData() : BinaryFunctionPass(false) {}

  const char *getName() const override {
    return "riscv-instrumentation-far-data";
  }
  Error runOnFunctions(BinaryContext &BC) override;
};

} // namespace bolt
} // namespace llvm

#endif
