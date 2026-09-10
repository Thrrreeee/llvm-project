//===- RISCVRelaxationPass.cpp ---------------------------------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "bolt/Passes/RISCVRelaxationPass.h"
#include "bolt/Passes/DataflowInfoManager.h"
#include "bolt/Passes/RegAnalysis.h"

using namespace llvm;
using namespace llvm::bolt;

namespace {

/// Restrict scratch registers to temporaries that are not referenced by CFI.
BitVector getScratchRegs(BinaryFunction &BF) {
  BinaryContext &BC = BF.getBinaryContext();
  BitVector Regs(BC.MRI->getNumRegs());
  for (unsigned DwarfReg : {5, 6, 7, 10, 11, 12, 13, 14, 15, 16, 17, 28, 29, 30,
                           31})
    Regs.set(*BC.MRI->getLLVMRegNum(DwarfReg, false));
  SmallVector<const MCCFIInstruction *> CFIs;
  for (const MCCFIInstruction &CFI :
       llvm::make_range(BF.cie_begin(), BF.cie_end()))
    CFIs.push_back(&CFI);
  for (const BinaryBasicBlock &BB : BF)
    for (const MCInst &Inst : BB)
      if (const MCCFIInstruction *CFI = BF.getCFIFor(Inst))
        CFIs.push_back(CFI);
  for (const MCCFIInstruction *CFIPtr : CFIs) {
    const MCCFIInstruction &CFI = *CFIPtr;
    switch (CFI.getOperation()) {
    case MCCFIInstruction::OpEscape:
      return BitVector(Regs.size());
    case MCCFIInstruction::OpRegister:
      if (auto Reg = BC.MRI->getLLVMRegNum(CFI.getRegister2(), false))
        Regs.reset(*Reg);
      [[fallthrough]];
    case MCCFIInstruction::OpDefCfa:
    case MCCFIInstruction::OpDefCfaRegister:
    case MCCFIInstruction::OpLLVMDefAspaceCfa:
    case MCCFIInstruction::OpOffset:
    case MCCFIInstruction::OpRelOffset:
    case MCCFIInstruction::OpValOffset:
    case MCCFIInstruction::OpRestore:
    case MCCFIInstruction::OpUndefined:
    case MCCFIInstruction::OpSameValue:
      if (auto Reg = BC.MRI->getLLVMRegNum(CFI.getRegister(), false))
        Regs.reset(*Reg);
      break;
    default:
      break;
    }
  }
  return Regs;
}

void keepFragmentsTogether(BinaryFunction &BF) {
  BinaryFunction::BasicBlockOrderType Order(BF.getLayout().block_begin(),
                                            BF.getLayout().block_end());
  for (BinaryBasicBlock *BB : Order)
    BB->setFragmentNum(FragmentNum::main());
  BF.getLayout().update(Order);
  if (BF.hasEHRanges())
    BF.setLPFragment(FragmentNum::main(), FragmentNum::main());
  BF.fixBranches();
}

bool relaxFunction(BinaryFunction &BF, RegAnalysis &RA) {
  BinaryContext &BC = BF.getBinaryContext();
  BitVector Candidates = getScratchRegs(BF);
  DenseMap<BinaryBasicBlock *, MCPhysReg> ScratchRegs;
  {
    DataflowInfoManager DIM(BF, &RA, nullptr);
    LivenessAnalysis &LA = DIM.getLivenessAnalysis();
    for (BinaryBasicBlock &BB : BF) {
      for (BinaryBasicBlock *Target : BB.successors()) {
        if (Target->getFragmentNum() == BB.getFragmentNum())
          continue;
        BitVector Dead = *LA.getStateAt(ProgramPoint::getFirstPointAt(*Target));
        Dead.flip();
        Dead &= Candidates;
        // There is no ABI-reserved temporary for arbitrary intra-function
        // branches on RISC-V. Never insert a clobber when no register is dead.
        if (Dead.none()) {
          BC.errs() << "BOLT-WARNING: keeping " << BF
                    << " unsplit: no dead register for a RISC-V long jump\n";
          DIM.invalidateLivenessAnalysis();
          keepFragmentsTogether(BF);
          return false;
        }
        ScratchRegs[Target] = Dead.find_first();
      }
    }
  }

  struct Edge {
    BinaryBasicBlock *Source;
    BinaryBasicBlock *Target;
    BinaryBasicBlock *Stub;
  };
  SmallVector<Edge> Edges;
  for (BinaryBasicBlock &BB : BF)
    for (BinaryBasicBlock *Target : BB.successors())
      if (Target->getFragmentNum() != BB.getFragmentNum())
        Edges.push_back({&BB, Target, nullptr});

  for (Edge &E : Edges) {
    auto Stub = BF.createBasicBlock();
    E.Stub = Stub.get();
    const auto BI = E.Source->getBranchInfo(*E.Target);
    Stub->setFragmentNum(E.Source->getFragmentNum());
    Stub->setExecutionCount(BI.Count);
    Stub->addSuccessor(E.Target, BI.Count, BI.MispredictedCount);
    E.Source->replaceSuccessor(E.Target, Stub.get(), BI.Count,
                               BI.MispredictedCount);
    std::vector<std::unique_ptr<BinaryBasicBlock>> NewBlocks;
    NewBlocks.push_back(std::move(Stub));
    BF.insertBasicBlocks(E.Source, std::move(NewBlocks));
  }
  BF.fixBranches();
  for (const Edge &E : Edges) {
    MCInst Jump;
    BC.MIB->createLongBranch(Jump, E.Target->getLabel(), ScratchRegs[E.Target],
                             BC.Ctx.get());
    E.Stub->clear();
    E.Stub->addInstruction(Jump);
  }
  return true;
}

} // namespace

Error RISCVRelaxationPass::runOnFunctions(BinaryContext &BC) {
  RegAnalysis RA(BC, nullptr, nullptr);
  unsigned Relaxed = 0, KeptTogether = 0;
  for (auto &[Address, BF] : BC.getBinaryFunctions()) {
    if (!BC.shouldEmit(BF) || !BF.isSimple() || !BF.isSplit())
      continue;
    if (relaxFunction(BF, RA))
      ++Relaxed;
    else
      ++KeptTogether;
  }
  BC.outs() << "BOLT-INFO: RISC-V relaxed branches in " << Relaxed
            << " split functions; kept " << KeptTogether
            << " functions together without a dead scratch register\n";
  return Error::success();
}
