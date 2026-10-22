//===- bolt/Target/RISCV/RISCVInstrumentationFarData.cpp
//--------------------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "bolt/Passes/RISCVInstrumentationFarData.h"
#include "MCTargetDesc/RISCVMCAsmInfo.h"
#include "MCTargetDesc/RISCVMCTargetDesc.h"
#include "bolt/Utils/CommandLineOpts.h"
#include "llvm/MC/MCInstBuilder.h"
#include "llvm/MC/MCValue.h"
#include "llvm/Support/Endian.h"

using namespace llvm;

namespace opts {
extern cl::OptionCategory BoltOptCategory;
bool inliningEnabled();
cl::opt<bool> RISCVInstrumentationFarData(
    "riscv-instrumentation-far-data",
    cl::desc(
        "use runtime-relocated slots for fixed-data RISC-V instrumentation "
        "references"),
    cl::init(false), cl::Hidden, cl::cat(BoltOptCategory));
} // namespace opts

namespace llvm {
namespace bolt {
namespace {

struct HighReference {
  BinaryBasicBlock *BB;
  size_t Index;
  uint64_t OriginalBase;
  MCSymbol *Anchor;
};

struct LowReference {
  MCInst *Inst;
  unsigned Operand;
  int64_t Immediate;
};

/// Match only data that stays at its original address. In particular, an input
/// GOT entry is fixed even though the object whose address it contains can
/// move.
static std::optional<uint64_t> getFixedTarget(BinaryContext &BC,
                                              const MCInst &Inst) {
  const MCExpr *Expr = BC.MIB->getRISCVPCRelHi20Expr(Inst);
  if (!Expr)
    return std::nullopt;
  MCValue Value;
  if (!Expr->evaluateAsRelocatable(Value, nullptr) || Value.getSubSym() ||
      Value.getSpecifier() || !Value.getAddSym())
    return std::nullopt;
  const MCSymbol &Symbol = *Value.getAddSym();
  const BinaryData *SymbolBD = BC.getBinaryDataByName(Symbol.getName());
  if (!SymbolBD)
    return std::nullopt;
  const uint64_t Target = SymbolBD->getAddress() + Value.getConstant();
  ErrorOr<BinarySection &> Section = BC.getSectionForAddress(Target);
  const BinaryData *TargetBD = BC.getBinaryDataContainingAddress(Target);
  auto MayMove = [](const BinaryData *BD) {
    return BD && (BD->isMoved() || BD->getRootData()->isMoved() ||
                  BD->isJumpTable() || BD->getRootData()->isJumpTable());
  };
  if (!Section || !Section->isAllocatable() || Section->isText() ||
      Section->isReordered() || MayMove(SymbolBD) || MayMove(TargetBD) ||
      BC.forceSymbolRelocations(Symbol.getName()) ||
      BC.getFunctionForSymbol(&Symbol) ||
      BC.getBinaryFunctionContainingAddress(Target))
    return std::nullopt;
  return Target;
}

static std::optional<uint32_t> getOriginalWord(BinaryFunction &BF,
                                               const MCInst &Inst) {
  const auto Offset = BF.getBinaryContext().MIB->getOffset(Inst);
  ErrorOr<ArrayRef<uint8_t>> Bytes = BF.getData();
  if (!Offset || !Bytes || *Offset > Bytes->size() ||
      Bytes->size() - *Offset < 4)
    return std::nullopt;
  return support::endian::read32le(Bytes->data() + *Offset);
}

/// Recover the decoded low immediate, not the symbolic target's new low bits.
/// PCREL_LO12_I/S are attached to standard 32-bit I/S instruction encodings.
static std::optional<int64_t> getOriginalLow(BinaryFunction &BF,
                                             const MCInst &Inst) {
  const auto Word = getOriginalWord(BF, Inst);
  if (!Word)
    return std::nullopt;
  switch (*Word & 0x7f) {
  case 0x03: // Integer load.
  case 0x07: // Floating-point load.
  case 0x13: // Integer immediate arithmetic.
  case 0x1b: // RV64 immediate arithmetic.
  case 0x67: // JALR.
    return SignExtend64<12>(*Word >> 20);
  case 0x23: // Integer store.
  case 0x27: // Floating-point store.
    return SignExtend64<12>(((*Word >> 20) & 0xfe0) | ((*Word >> 7) & 0x1f));
  default:
    return std::nullopt;
  }
}

/// Validate the entire function before changing an instruction or allocating a
/// slot. Offsets still refer to this input function: the pass precedes
/// inlining.
static bool collectReferences(BinaryFunction &BF,
                              SmallVectorImpl<HighReference> &Highs,
                              SmallVectorImpl<LowReference> &Lows) {
  BinaryContext &BC = BF.getBinaryContext();
  DenseMap<const MCSymbol *, size_t> Anchors;
  DenseSet<const MCSymbol *> KnownAnchors;
  for (BinaryBasicBlock &BB : BF) {
    for (size_t I = 0; I != BB.size(); ++I) {
      MCInst &Inst = BB.getInstructionAtIndex(I);
      if (BC.MIB->getRISCVPCRelHi20Expr(Inst))
        if (const MCSymbol *Anchor = BC.MIB->getInstLabel(Inst))
          if (!KnownAnchors.insert(Anchor).second)
            return false;
      const auto Target = getFixedTarget(BC, Inst);
      if (!Target)
        continue;
      const auto Word = getOriginalWord(BF, Inst);
      const auto Offset = BC.MIB->getOffset(Inst);
      const MCRegister Reg = Inst.getOperand(0).getReg();
      // Asynchronous handlers can use SP, GP, and TP before the added load
      // restores the original base. Do not expose a slot address in them.
      if (!Word || !Offset || (*Word & 0x7f) != 0x17 || Reg == RISCV::X0 ||
          Reg == RISCV::X2 || Reg == RISCV::X3 || Reg == RISCV::X4 ||
          BC.MRI->getEncodingValue(Reg) != ((*Word >> 7) & 31))
        return false;
      const uint64_t OriginalBase =
          BF.getAddress() + *Offset + SignExtend64<32>(*Word & 0xfffff000);
      // A changed symbolic target must not be silently restored to an old one.
      if (!isInt<12>(static_cast<int64_t>(*Target - OriginalBase)))
        return false;
      MCSymbol *Anchor = BC.MIB->getInstLabel(Inst);
      if (Anchor && !Anchors.try_emplace(Anchor, Highs.size()).second)
        return false;
      Highs.push_back({&BB, I, OriginalBase, Anchor});
    }
  }

  if (Highs.empty())
    return true;

  // InstructionReferences in the symbolizer stores only the first low use of
  // each high instruction. Scan all current operands, including other blocks,
  // so every symbolic consumer of a transformed base becomes numeric again.
  for (BinaryBasicBlock &BB : BF) {
    for (MCInst &Inst : BB) {
      for (unsigned I = 0, E = MCPlus::getNumPrimeOperands(Inst); I != E; ++I) {
        const MCOperand &Operand = Inst.getOperand(I);
        if (!Operand.isExpr())
          continue;
        const auto *Expr = dyn_cast<MCSpecifierExpr>(Operand.getExpr());
        if (!Expr || Expr->getSpecifier() != RISCV::S_PCREL_LO)
          continue;
        MCValue Value;
        if (!Expr->getSubExpr()->evaluateAsRelocatable(Value, nullptr) ||
            !Value.getAddSym() || Value.getSubSym() || Value.getSpecifier() ||
            Value.getConstant() || !KnownAnchors.contains(Value.getAddSym()))
          return false;
        if (!Anchors.contains(Value.getAddSym()))
          continue;
        const auto Immediate = getOriginalLow(BF, Inst);
        if (!Immediate)
          return false;
        Lows.push_back({&Inst, I, *Immediate});
      }
    }
  }
  return true;
}

} // namespace

Error RISCVInstrumentationFarData::runOnFunctions(BinaryContext &BC) {
  if (!opts::RISCVInstrumentationFarData)
    return Error::success();
  if (!opts::Instrument || !BC.TheTriple->isRISCV64() ||
      !BC.SupportsRISCVFarDataSlots || !BC.HasRelocations)
    return createFatalBOLTError(
        "--riscv-instrumentation-far-data requires RISC-V64 --instrument "
        "on a supported dynamically linked PIE with relocations");
  if (!opts::ReorderData.empty())
    return createFatalBOLTError(
        "--riscv-instrumentation-far-data does not support --reorder-data");
  if (opts::inliningEnabled())
    return createFatalBOLTError(
        "--riscv-instrumentation-far-data does not support inlining; "
        "use --no-inline to retain the original functions' placement limits");

  // Original FDEs can contain signed 32-bit references to fixed input code.
  // Copying them past a large instrumented text section can overflow those
  // fields, independently of the instruction references handled below.
  BC.KeepOriginalEHFrame = true;
  BC.UseLargeCodeModel = true;
  BC.updateLSDAEncoding();

  uint64_t NumHighs = 0, NumLows = 0, NumLRSC = 0, NumNonSimple = 0;
  uint64_t NumUnverified = 0;
  for (auto &[Address, BF] : BC.getBinaryFunctions()) {
    if (!BC.shouldEmit(BF) || !BF.hasCFG())
      continue;
    bool HasLRSC = false;
    for (const BinaryBasicBlock &BB : BF)
      for (const MCInst &Inst : BB)
        HasLRSC |= BC.MIB->isRISCVLRSC(Inst);
    // Adding even one ordinary load between LR and SC can invalidate a
    // constrained reservation loop. Keep all such functions unmodified here.
    if (HasLRSC || !BF.isSimple()) {
      BC.RISCVFarDataEarlyFunctions.insert(&BF);
      HasLRSC ? ++NumLRSC : ++NumNonSimple;
      continue;
    }

    SmallVector<HighReference, 4> Highs;
    SmallVector<LowReference, 4> Lows;
    if (!collectReferences(BF, Highs, Lows)) {
      BC.RISCVFarDataEarlyFunctions.insert(&BF);
      ++NumUnverified;
      continue;
    }
    // Finish all low-operand updates before inserting instructions invalidates
    // their pointers. Numeric consumers already retain their original values.
    for (const LowReference &Low : Lows)
      Low.Inst->getOperand(Low.Operand) = MCOperand::createImm(Low.Immediate);
    for (const HighReference &High : llvm::reverse(Highs)) {
      auto I = High.BB->begin() + High.Index;
      const MCRegister Reg = I->getOperand(0).getReg();
      MCSymbol *Slot = BC.getOrCreateRISCVFarDataSlot(High.OriginalBase);
      MCSymbol *Anchor = High.Anchor;
      if (!Anchor) {
        Anchor = BC.Ctx->createNamedTempSymbol("far_data_hi");
        BC.MIB->setInstLabel(*I, Anchor);
      }
      BC.MIB->setOperandToSymbolRef(*I, 1, Slot, 0, BC.Ctx.get(),
                                    ELF::R_RISCV_PCREL_HI20);
      MCInst Load = MCInstBuilder(RISCV::LD).addReg(Reg).addReg(Reg).addImm(0);
      BC.MIB->setOperandToSymbolRef(Load, 2, Anchor, 0, BC.Ctx.get(),
                                    ELF::R_RISCV_PCREL_LO12_I);
      High.BB->insertInstruction(I + 1, std::move(Load));
    }
    NumHighs += Highs.size();
    NumLows += Lows.size();
  }
  BC.outs() << "BOLT-INFO: RISC-V far-data slots replaced " << NumHighs
            << " AUIPC references and restored " << NumLows
            << " low operands; kept " << NumLRSC << " LR/SC functions, "
            << NumNonSimple << " non-simple functions, and " << NumUnverified
            << " functions with unverified references for early placement\n";
  return Error::success();
}

} // namespace bolt
} // namespace llvm
