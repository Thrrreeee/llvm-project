//===- RISCVRelaxationPass.h -----------------------------------*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#ifndef BOLT_PASSES_RISCVRELAXATIONPASS_H
#define BOLT_PASSES_RISCVRELAXATIONPASS_H

#include "bolt/Passes/BinaryPasses.h"

namespace llvm::bolt {

/// Make branches between function fragments independent of the JAL range.
class RISCVRelaxationPass : public BinaryFunctionPass {
public:
  RISCVRelaxationPass() : BinaryFunctionPass(false) {}
  const char *getName() const override { return "riscv-relaxation"; }
  Error runOnFunctions(BinaryContext &BC) override;
};

} // namespace llvm::bolt

#endif
