//===- bolt/Passes/ReorderFunctions.cpp - Function reordering pass --------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements ReorderFunctions class.
//
//===----------------------------------------------------------------------===//

#include "bolt/Passes/ReorderFunctions.h"
#include "bolt/Passes/HFSort.h"
#include "bolt/Utils/CommandLineOpts.h"
#include "bolt/Utils/Utils.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/StringMap.h"
#include "llvm/MC/MCValue.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/Support/JSON.h"
#include "llvm/Transforms/Utils/CodeLayout.h"
#include <fstream>

#define DEBUG_TYPE "hfsort"

using namespace llvm;

namespace opts {

extern cl::OptionCategory BoltOptCategory;
extern cl::opt<unsigned> Verbosity;
extern cl::opt<uint32_t> RandomSeed;

extern size_t padFunctionBefore(const bolt::BinaryFunction &Function);
extern size_t padFunctionAfter(const bolt::BinaryFunction &Function);

extern cl::opt<bolt::ReorderFunctions::ReorderType> ReorderFunctions;
cl::opt<bolt::ReorderFunctions::ReorderType> ReorderFunctions(
    "reorder-functions",
    cl::desc("reorder and cluster functions (works only with relocations)"),
    cl::init(bolt::ReorderFunctions::RT_NONE),
    cl::values(clEnumValN(bolt::ReorderFunctions::RT_NONE, "none",
                          "do not reorder functions"),
               clEnumValN(bolt::ReorderFunctions::RT_EXEC_COUNT, "exec-count",
                          "order by execution count"),
               clEnumValN(bolt::ReorderFunctions::RT_HFSORT, "hfsort",
                          "use hfsort algorithm"),
               clEnumValN(bolt::ReorderFunctions::RT_HFSORT_PLUS, "hfsort+",
                          "use cache-directed sort"),
               clEnumValN(bolt::ReorderFunctions::RT_CDSORT, "cdsort",
                          "use cache-directed sort"),
               clEnumValN(bolt::ReorderFunctions::RT_PETTIS_HANSEN,
                          "pettis-hansen", "use Pettis-Hansen algorithm"),
               clEnumValN(bolt::ReorderFunctions::RT_RANDOM, "random",
                          "reorder functions randomly"),
               clEnumValN(bolt::ReorderFunctions::RT_USER, "user",
                          "use function order specified by -function-order")),
    cl::cat(BoltOptCategory));

static cl::opt<bool> ReorderFunctionsUseHotSize(
    "reorder-functions-use-hot-size",
    cl::desc("use a function's hot size when doing clustering"), cl::init(true),
    cl::cat(BoltOptCategory));

static cl::opt<std::string> FunctionOrderFile(
    "function-order",
    cl::desc("file containing an ordered list of functions to use for function "
             "reordering; can be combined with --reorder-functions algorithms"),
    cl::cat(BoltOptCategory));

static cl::opt<std::string> GenerateFunctionOrderFile(
    "generate-function-order",
    cl::desc("file to dump the ordered list of functions to use for function "
             "reordering"),
    cl::cat(BoltOptCategory));

static cl::opt<std::string> RISCVInstrumentationLayoutReport(
    "riscv-instrumentation-layout-report",
    cl::desc("write a read-only JSONL estimate of instrumented RISC-V function "
             "sizes and fixed-data PC-relative windows"),
    cl::Hidden, cl::cat(BoltOptCategory));

static cl::opt<std::string> RISCVInstrumentationOrderFile(
    "riscv-instrumentation-order-file",
    cl::desc("with --riscv-instrumentation-layout-report, write a candidate "
             "--function-order list sorted by fixed-data window deadlines"),
    cl::Hidden, cl::cat(BoltOptCategory));

static cl::opt<std::string> LinkSectionsFile(
    "generate-link-sections",
    cl::desc("generate a list of function sections in a format suitable for "
             "inclusion in a linker script"),
    cl::cat(BoltOptCategory));

static cl::opt<bool>
    UseEdgeCounts("use-edge-counts",
                  cl::desc("use edge count data when doing clustering"),
                  cl::init(true), cl::cat(BoltOptCategory));

static cl::opt<bool> CgFromPerfData(
    "cg-from-perf-data",
    cl::desc("use perf data directly when constructing the call graph"
             " for stale functions"),
    cl::init(true), cl::cat(BoltOptCategory));

static cl::opt<bool> CgIgnoreRecursiveCalls(
    "cg-ignore-recursive-calls",
    cl::desc("ignore recursive calls when constructing the call graph"),
    cl::init(true), cl::cat(BoltOptCategory));

static cl::opt<bool> CgUseSplitHotSize(
    "cg-use-split-hot-size",
    cl::desc("use hot/cold data on basic blocks to determine hot sizes for "
             "call graph functions"),
    cl::init(false), cl::cat(BoltOptCategory));

} // namespace opts

namespace llvm {
namespace bolt {

using NodeId = CallGraph::NodeId;
using Arc = CallGraph::Arc;
using Node = CallGraph::Node;

void ReorderFunctions::reorder(BinaryContext &BC,
                               std::vector<Cluster> &&Clusters,
                               std::map<uint64_t, BinaryFunction> &BFs,
                               uint32_t StartIndex) {
  std::vector<uint64_t> FuncAddr(Cg.numNodes()); // Just for computing stats
  uint64_t TotalSize = 0;
  uint32_t Index = StartIndex;

  // Set order of hot functions based on clusters.
  for (const Cluster &Cluster : Clusters) {
    for (const NodeId FuncId : Cluster.targets()) {
      Cg.nodeIdToFunc(FuncId)->setIndex(Index++);
      FuncAddr[FuncId] = TotalSize;
      TotalSize += Cg.size(FuncId);
    }
  }

  // Assign valid index for functions with valid profile.
  for (auto &It : BFs) {
    BinaryFunction &BF = It.second;
    if (!BF.hasValidIndex() && BF.hasValidProfile())
      BF.setIndex(Index++);
  }

  if (opts::ReorderFunctions == RT_NONE)
    return;

  printStats(BC, Clusters, FuncAddr);
}

void ReorderFunctions::printStats(BinaryContext &BC,
                                  const std::vector<Cluster> &Clusters,
                                  const std::vector<uint64_t> &FuncAddr) {
  if (opts::Verbosity == 0) {
#ifndef NDEBUG
    if (!DebugFlag || !isCurrentDebugType("hfsort"))
      return;
#else
    return;
#endif
  }

  bool PrintDetailed = opts::Verbosity > 1;
#ifndef NDEBUG
  PrintDetailed |=
      (DebugFlag && isCurrentDebugType("hfsort") && opts::Verbosity > 0);
#endif
  uint64_t TotalSize = 0;
  uint64_t CurPage = 0;
  uint64_t Hotfuncs = 0;
  double TotalDistance = 0;
  double TotalCalls = 0;
  double TotalCalls64B = 0;
  double TotalCalls4KB = 0;
  double TotalCalls2MB = 0;
  if (PrintDetailed)
    BC.outs() << "BOLT-INFO: Function reordering page layout\n"
              << "BOLT-INFO: ============== page 0 ==============\n";
  for (const Cluster &Cluster : Clusters) {
    if (PrintDetailed)
      BC.outs() << format(
          "BOLT-INFO: -------- density = %.3lf (%u / %u) --------\n",
          Cluster.density(), Cluster.samples(), Cluster.size());

    for (NodeId FuncId : Cluster.targets()) {
      if (Cg.samples(FuncId) > 0) {
        Hotfuncs++;

        if (PrintDetailed)
          BC.outs() << "BOLT-INFO: hot func " << *Cg.nodeIdToFunc(FuncId)
                    << " (" << Cg.size(FuncId) << ")\n";

        uint64_t Dist = 0;
        uint64_t Calls = 0;
        for (NodeId Dst : Cg.successors(FuncId)) {
          if (FuncId == Dst) // ignore recursive calls in stats
            continue;
          const Arc &Arc = *Cg.findArc(FuncId, Dst);
          const auto D = std::abs(FuncAddr[Arc.dst()] -
                                  (FuncAddr[FuncId] + Arc.avgCallOffset()));
          const double W = Arc.weight();
          if (D < 64 && PrintDetailed && opts::Verbosity > 2)
            BC.outs() << "BOLT-INFO: short (" << D << "B) call:\n"
                      << "BOLT-INFO:   Src: " << *Cg.nodeIdToFunc(FuncId)
                      << "\n"
                      << "BOLT-INFO:   Dst: " << *Cg.nodeIdToFunc(Dst) << "\n"
                      << "BOLT-INFO:   Weight = " << W << "\n"
                      << "BOLT-INFO:   AvgOffset = " << Arc.avgCallOffset()
                      << "\n";
          Calls += W;
          if (D < 64)
            TotalCalls64B += W;
          if (D < 4096)
            TotalCalls4KB += W;
          if (D < (2 << 20))
            TotalCalls2MB += W;
          Dist += Arc.weight() * D;
          if (PrintDetailed)
            BC.outs() << format("BOLT-INFO: arc: %u [@%lu+%.1lf] -> %u [@%lu]: "
                                "weight = %.0lf, callDist = %f\n",
                                Arc.src(), FuncAddr[Arc.src()],
                                Arc.avgCallOffset(), Arc.dst(),
                                FuncAddr[Arc.dst()], Arc.weight(), D);
        }
        TotalCalls += Calls;
        TotalDistance += Dist;
        TotalSize += Cg.size(FuncId);

        if (PrintDetailed) {
          BC.outs() << format("BOLT-INFO: start = %6u : avgCallDist = %lu : ",
                              TotalSize, Calls ? Dist / Calls : 0)
                    << Cg.nodeIdToFunc(FuncId)->getPrintName() << '\n';
          const uint64_t NewPage = TotalSize / HugePageSize;
          if (NewPage != CurPage) {
            CurPage = NewPage;
            BC.outs() << format(
                "BOLT-INFO: ============== page %u ==============\n", CurPage);
          }
        }
      }
    }
  }
  BC.outs() << "BOLT-INFO: Function reordering stats\n"
            << format("BOLT-INFO:  Number of hot functions: %u\n"
                      "BOLT-INFO:  Number of clusters: %lu\n",
                      Hotfuncs, Clusters.size())
            << format("BOLT-INFO:  Final average call distance = %.1lf "
                      "(%.0lf / %.0lf)\n",
                      TotalCalls ? TotalDistance / TotalCalls : 0,
                      TotalDistance, TotalCalls)
            << format("BOLT-INFO:  Total Calls = %.0lf\n", TotalCalls);
  if (TotalCalls)
    BC.outs()
        << format("BOLT-INFO:  Total Calls within 64B = %.0lf (%.2lf%%)\n",
                  TotalCalls64B, 100 * TotalCalls64B / TotalCalls)
        << format("BOLT-INFO:  Total Calls within 4KB = %.0lf (%.2lf%%)\n",
                  TotalCalls4KB, 100 * TotalCalls4KB / TotalCalls)
        << format("BOLT-INFO:  Total Calls within 2MB = %.0lf (%.2lf%%)\n",
                  TotalCalls2MB, 100 * TotalCalls2MB / TotalCalls);
}

Error ReorderFunctions::readFunctionOrderFile(
    std::vector<std::string> &FunctionNames) {
  std::ifstream FuncsFile(opts::FunctionOrderFile, std::ios::in);
  if (!FuncsFile)
    return createFatalBOLTError(Twine("Ordered functions file \"") +
                                Twine(opts::FunctionOrderFile) +
                                Twine("\" can't be opened."));

  std::string FuncName;
  while (std::getline(FuncsFile, FuncName))
    FunctionNames.push_back(FuncName);
  return Error::success();
}

/// Resolve an exact order-file name without expanding local or LTO suffixes.
/// A disengaged optional means the name was not found. A null function means
/// an exact name exists but does not identify an unambiguous function.
static std::optional<BinaryFunction *>
resolveExactFunctionOrderName(BinaryContext &BC, StringRef Name) {
  const BinaryData *BD = BC.getBinaryDataByName(Name);
  BinaryFunction *DataFunction =
      BD ? BC.getFunctionForSymbol(BD->getSymbol()) : nullptr;
  const MCSymbol *Symbol = BC.Ctx->lookupSymbol(Name);
  BinaryFunction *SymbolFunction =
      Symbol ? BC.getFunctionForSymbol(Symbol) : nullptr;

  if (!BD && !SymbolFunction)
    return std::nullopt;
  if (DataFunction && SymbolFunction && DataFunction != SymbolFunction)
    return nullptr;
  if (DataFunction)
    return DataFunction;

  // FDE-created functions can share BinaryData with an earlier local marker
  // whose primary symbol is not mapped to a function. Keep the exact function
  // symbol's identity, and require the same entry address when data exists.
  if (SymbolFunction &&
      (!BD || BD->getAddress() == SymbolFunction->getAddress()))
    return SymbolFunction;
  return nullptr;
}

Expected<uint32_t> ReorderFunctions::assignFunctionOrder(
    BinaryContext &BC, std::map<uint64_t, BinaryFunction> &BFs,
    uint32_t StartIndex, DenseSet<const BinaryFunction *> *OrderedFuncs) {
  // Build LTOCommonNameMap for name resolution.
  StringMap<std::vector<uint64_t>> LTOCommonNameMap;
  for (const BinaryFunction &BF : llvm::make_second_range(BFs))
    for (StringRef Name : BF.getNames())
      if (std::optional<StringRef> LTOCommonName = getLTOCommonName(Name))
        LTOCommonNameMap[*LTOCommonName].push_back(BF.getAddress());

  uint32_t Index = StartIndex;
  uint32_t InvalidEntries = 0;
  std::vector<std::string> FunctionNames;
  if (Error E = readFunctionOrderFile(FunctionNames))
    return std::move(E);

  for (const std::string &Function : FunctionNames) {
    std::vector<BinaryFunction *> Functions;

    if (std::optional<BinaryFunction *> BF =
            resolveExactFunctionOrderName(BC, Function)) {
      Functions.push_back(*BF);
    } else {
      // If we can't find the main symbol name, look for alternates.
      uint32_t LocalID = 1;
      while (true) {
        const std::string FuncName = Function + "/" + std::to_string(LocalID);
        if (std::optional<BinaryFunction *> BF =
                resolveExactFunctionOrderName(BC, FuncName))
          Functions.push_back(*BF);
        else
          break;
        LocalID++;
      }
      // Strip LTO suffixes.
      if (std::optional<StringRef> CommonName = getLTOCommonName(Function))
        if (LTOCommonNameMap.contains(*CommonName))
          for (uint64_t Address : LTOCommonNameMap[*CommonName]) {
            const BinaryData *BD = BC.getBinaryDataAtAddress(Address);
            Functions.push_back(BD ? BC.getFunctionForSymbol(BD->getSymbol())
                                   : nullptr);
          }
    }

    if (Functions.empty()) {
      if (opts::Verbosity >= 1)
        BC.errs() << "BOLT-WARNING: Reorder functions: can't find function "
                  << "for " << Function << "\n";
      ++InvalidEntries;
      continue;
    }

    for (BinaryFunction *BF : Functions) {
      if (!BF) {
        if (opts::Verbosity >= 1)
          BC.errs() << "BOLT-WARNING: Reorder functions: can't find function "
                    << "for " << Function << "\n";
        ++InvalidEntries;
        break;
      }
      if (!BF->hasValidIndex()) {
        BF->setIndex(Index++);
        if (OrderedFuncs)
          OrderedFuncs->insert(BF);
      } else if (opts::Verbosity > 0) {
        BC.errs() << "BOLT-WARNING: Duplicate reorder entry for " << Function
                  << "\n";
      }
    }
  }
  if (InvalidEntries)
    BC.errs() << "BOLT-WARNING: Reorder functions: can't find functions for "
              << InvalidEntries << " entries in -function-order list\n";

  return Index;
}

namespace {

/// A diagnostic model, not an alternative to relocation validation. Requiring
/// the entire function to fit every fixed-data window avoids assuming that an
/// AUIPC retains its current offset during subsequent passes.
struct RISCVLayoutRecord {
  const BinaryFunction *Function;
  uint64_t Size{0};
  uint64_t AlignmentBudget{0};
  uint64_t EarliestStart{0};
  uint64_t LatestEnd{std::numeric_limits<uint64_t>::max()};
  uint64_t FixedReferences{0};
  uint64_t UnresolvedReferences{0};
  uint64_t NonFixedReferences{0};
  bool OrderNameVerified{false};
};

static Error reportRISCVInstrumentationLayout(BinaryContext &BC) {
  if (opts::RISCVInstrumentationLayoutReport.empty()) {
    if (!opts::RISCVInstrumentationOrderFile.empty())
      return createFatalBOLTError("--riscv-instrumentation-order-file requires "
                                  "--riscv-instrumentation-layout-report");
    return Error::success();
  }
  if (BC.TheTriple->getArch() != Triple::riscv64 || !opts::Instrument)
    return createFatalBOLTError(
        "--riscv-instrumentation-layout-report requires RISC-V64 "
        "--instrument");
  if (opts::RISCVInstrumentationLayoutReport ==
      opts::RISCVInstrumentationOrderFile)
    return createFatalBOLTError("layout report and order file must differ");

  // JITLink requires displacement + 0x800 to fit in signed 32 bits. Thus an
  // AUIPC addressing T must be at a PC in [T - Forward, T + Backward]. Use an
  // exclusive function end no greater than the latter bound (conservative).
  constexpr uint64_t Forward = 0x7ffff7ff;
  constexpr uint64_t Backward = 0x80000800;
  std::vector<RISCVLayoutRecord> Records;
  Records.reserve(BC.getBinaryFunctions().size());
  uint64_t SplitFunctions = 0;
  uint64_t IslandFunctions = 0;
  bool AllOrderNamesVerified = true;

  for (const auto &[Address, BF] : BC.getBinaryFunctions()) {
    if (!BC.shouldEmit(BF))
      continue;
    RISCVLayoutRecord R{&BF};
    R.Size = BF.estimateSize() + BF.estimateConstantIslandSize();
    // Account for mandatory and optional function alignment independently.
    // BinaryEmitter omits optional alignment when its maximum is zero.
    R.AlignmentBudget = BF.getMinAlignment() - 1;
    R.AlignmentBudget +=
        opts::padFunctionBefore(BF) + opts::padFunctionAfter(BF);
    // AlignerPass normally replaces the current function settings with the
    // global settings. Bound both states in case alignment is preserved.
    const uint64_t CurrentAlignmentBudget = std::min<uint64_t>(
        BF.getMaxAlignmentBytes(), std::max<unsigned>(1, BF.getAlignment()) - 1);
    const uint64_t FutureAlignmentBudget = std::min<uint64_t>(
        BC.AlignFunctionsMaxBytes, std::max(1U, BC.AlignFunctions) - 1);
    R.AlignmentBudget +=
        std::max(CurrentAlignmentBudget, FutureAlignmentBudget);
    if (BF.hasIslandsInfo()) {
      ++IslandFunctions;
      R.AlignmentBudget += BF.getConstantIslandAlignment() - 1;
    }
    SplitFunctions += BF.isSplit();

    // Use the same exact-name resolution as --function-order. Preserve local
    // /N suffixes instead of exporting getPrintName() or stripped ELF names.
    StringRef Name = BF.getOneName();
    if (std::optional<BinaryFunction *> Resolved =
            resolveExactFunctionOrderName(BC, Name)) {
      R.OrderNameVerified =
          *Resolved == &BF && !Name.empty() && !Name.contains('\n') &&
          !Name.contains('\r');
    }
    AllOrderNamesVerified &= R.OrderNameVerified;

    for (const BinaryBasicBlock &BB : BF) {
      uint64_t BlockBudget = BB.getAlignment() > 1 ? BB.getAlignment() - 1 : 0;
      if (BC.AlignBlocks && !BC.PreserveBlocksAlignment)
        BlockBudget = std::max<uint64_t>(BlockBudget,
                                        std::max(1U, BC.BlockAlignment) - 1);
      R.AlignmentBudget += BlockBudget;
      for (const MCInst &Inst : BB) {
        const MCExpr *Expr = BC.MIB->getRISCVPCRelHi20Expr(Inst);
        if (!Expr)
          continue;
        MCValue Value;
        if (!Expr->evaluateAsRelocatable(Value, nullptr) || Value.getSubSym() ||
            Value.getSpecifier() || !Value.getAddSym()) {
          ++R.UnresolvedReferences;
          continue;
        }
        const MCSymbol &Symbol = *Value.getAddSym();
        const BinaryData *SymbolBD = BC.getBinaryDataByName(Symbol.getName());
        if (!SymbolBD) {
          // Includes newly created instrumentation counters and runtime data.
          ++R.UnresolvedReferences;
          continue;
        }
        const uint64_t Target = SymbolBD->getAddress() + Value.getConstant();
        if (Target > uint64_t(INT64_MAX) - Backward) {
          ++R.UnresolvedReferences;
          continue;
        }
        // Resolve the effective address, not just the symbol: GOT references
        // can use __BOLT_got_zero + the original GOT address.
        ErrorOr<BinarySection &> Section = BC.getSectionForAddress(Target);
        const BinaryData *TargetBD = BC.getBinaryDataContainingAddress(Target);
        const bool TargetsJumpTable =
            BC.getJumpTableContainingAddress(Target) ||
            (Target != SymbolBD->getAddress() &&
             BC.getJumpTableContainingAddress(SymbolBD->getAddress()));
        auto MayMove = [](const BinaryData *BD) {
          return BD && (BD->isMoved() || BD->getRootData()->isMoved() ||
                        BD->isJumpTable() || BD->getRootData()->isJumpTable());
        };
        if (!Section || !Section->isAllocatable() || Section->isText() ||
            Section->isReordered() || TargetsJumpTable || MayMove(SymbolBD) ||
            MayMove(TargetBD) ||
            BC.forceSymbolRelocations(Symbol.getName()) ||
            BC.getFunctionForSymbol(&Symbol) ||
            BC.getBinaryFunctionContainingAddress(Target)) {
          ++R.NonFixedReferences;
          continue;
        }
        ++R.FixedReferences;
        R.EarliestStart =
            std::max(R.EarliestStart, Target > Forward ? Target - Forward : 0);
        R.LatestEnd = std::min(R.LatestEnd, Target + Backward);
      }
    }
    Records.push_back(R);
  }

  // Earliest deadline first, with input addresses breaking ties. The diagnostic
  // never modifies function indices or the actual layout.
  llvm::sort(Records,
             [](const RISCVLayoutRecord &A, const RISCVLayoutRecord &B) {
               return std::make_pair(A.LatestEnd, A.Function->getAddress()) <
                      std::make_pair(B.LatestEnd, B.Function->getAddress());
             });

  std::error_code EC;
  raw_fd_ostream Report(opts::RISCVInstrumentationLayoutReport, EC,
                        sys::fs::OF_Text);
  if (EC)
    return errorCodeToError(EC);
  std::unique_ptr<raw_fd_ostream> Order;
  if (AllOrderNamesVerified && !opts::RISCVInstrumentationOrderFile.empty()) {
    Order = std::make_unique<raw_fd_ostream>(
        opts::RISCVInstrumentationOrderFile, EC, sys::fs::OF_Text);
    if (EC)
      return errorCodeToError(EC);
  }

  const uint64_t Base =
      alignTo(BC.LayoutStartAddress,
              std::max<uint64_t>(1, std::max(BC.AlignText, BC.AlignFunctions)));
  Report
      << json::Object{{"kind", "model"},
                      {"version", 1},
                      {"model", "whole-function-fixed-data-window"},
                      {"stage", "reorder-functions"},
                      {"candidate_order",
                       "earliest-deadline-then-input-address"},
                      {"text_base_estimate", Base},
                      {"minimum_displacement", -int64_t(Backward)},
                      {"maximum_displacement", Forward},
                      {"use_old_text", bool(opts::UseOldText)},
                      {"hot_text", bool(opts::HotText)},
                      {"hot_functions_at_end", bool(opts::HotFunctionsAtEnd)},
                      {"data_reordering_requested", !opts::ReorderData.empty()},
                      {"note", "Read-only candidate, not proof of linkability. "
                               "Bounds cover "
                               "whole estimated functions and worst-case "
                               "alignment in one "
                               "contiguous text section. Later splitting, "
                               "section placement, "
                               "relaxation, calls, moved data, injected "
                               "functions, counters "
                               "and runtime references are not modeled. Final "
                               "JITLink range "
                               "checks remain necessary."}}
      << '\n';

  // Track the interval of possible PCs from zero to maximum alignment padding.
  // This uses one conservative window model, rather than interpreting an
  // optimistic placement of an individual AUIPC as a safety guarantee.
  uint64_t LowerCursor = Base;
  uint64_t UpperCursor = Base;
  uint64_t Violations = 0;
  uint64_t FixedReferences = 0;
  uint64_t UnresolvedReferences = 0;
  uint64_t NonFixedReferences = 0;
  uint64_t ConstrainedFunctions = 0;
  uint64_t UnverifiedNames = 0;
  uint64_t Rank = 0;
  for (const RISCVLayoutRecord &R : Records) {
    const BinaryFunction &BF = *R.Function;
    const uint64_t EndUpper = UpperCursor + R.AlignmentBudget + R.Size;
    const bool ViolatesWindow =
        LowerCursor < R.EarliestStart || EndUpper > R.LatestEnd;
    Violations += ViolatesWindow;
    FixedReferences += R.FixedReferences;
    UnresolvedReferences += R.UnresolvedReferences;
    NonFixedReferences += R.NonFixedReferences;
    ConstrainedFunctions += R.FixedReferences != 0;
    UnverifiedNames += !R.OrderNameVerified;
    Report << json::Object{{"kind", "function"},
                           {"name", BF.getOneName()},
                           {"input_address", BF.getAddress()},
                           {"input_size", BF.getSize()},
                           {"estimated_size", R.Size},
                           {"alignment_budget", R.AlignmentBudget},
                           {"fixed_references", R.FixedReferences},
                           {"unresolved_references", R.UnresolvedReferences},
                           {"nonfixed_references", R.NonFixedReferences},
                           {"window_start_lower", R.EarliestStart},
                           {"window_end_upper", R.FixedReferences
                                                    ? json::Value(R.LatestEnd)
                                                    : json::Value(nullptr)},
                           {"candidate_rank", Rank++},
                           {"candidate_start_lower", LowerCursor},
                           {"candidate_end_upper", EndUpper},
                           {"deadline_slack",
                            R.FixedReferences
                                ? json::Value(int64_t(R.LatestEnd) -
                                              int64_t(EndUpper))
                                : json::Value(nullptr)},
                           {"window_violation", ViolatesWindow},
                           {"order_name_verified", R.OrderNameVerified}}
           << '\n';
    if (Order)
      *Order << BF.getOneName() << '\n';
    LowerCursor += R.Size;
    UpperCursor = EndUpper;
  }
  Report << json::Object{{"kind", "summary"},
                         {"functions", Records.size()},
                         {"constrained_functions", ConstrainedFunctions},
                         {"estimated_bytes", LowerCursor - Base},
                         {"alignment_budget", UpperCursor - LowerCursor},
                         {"candidate_end_upper", UpperCursor},
                         {"window_violations", Violations},
                         {"fixed_references", FixedReferences},
                         {"unresolved_references", UnresolvedReferences},
                         {"nonfixed_references", NonFixedReferences},
                         {"split_functions", SplitFunctions},
                         {"island_functions", IslandFunctions},
                         {"order_file_written", bool(Order)},
                         {"unverified_order_names", UnverifiedNames}}
         << '\n';
  Report.flush();
  if (Report.has_error())
    return errorCodeToError(Report.error());
  if (Order) {
    Order->flush();
    if (Order->has_error())
      return errorCodeToError(Order->error());
  }
  if (!AllOrderNamesVerified && !opts::RISCVInstrumentationOrderFile.empty())
    BC.errs() << "BOLT-WARNING: " << UnverifiedNames
              << " function names do not round-trip through --function-order; "
                 "no order file was written. Any existing file at "
              << opts::RISCVInstrumentationOrderFile
              << " does not belong to this report\n";
  BC.outs()
      << "BOLT-INFO: RISC-V instrumentation layout report: " << Records.size()
      << " functions, " << Violations
      << " candidate window violations; final linkability is not proven\n";
  return Error::success();
}

} // namespace

Error ReorderFunctions::runOnFunctions(BinaryContext &BC) {
  if (Error E = reportRISCVInstrumentationLayout(BC))
    return E;
  auto &BFs = BC.getBinaryFunctions();

  if (opts::ReorderFunctions == RT_HFSORT_PLUS) {
    BC.errs() << "BOLT-WARNING: '-reorder-functions=hfsort+' is deprecated,"
              << " please use '-reorder-functions=cdsort' instead\n";
    opts::ReorderFunctions = RT_CDSORT;
  }

  // If a function order file is provided but no reorder algorithm was
  // explicitly specified, default to RT_USER.
  if (!opts::FunctionOrderFile.empty()) {
    if (opts::ReorderFunctions.getNumOccurrences() == 0) {
      opts::ReorderFunctions = RT_USER;
      BC.outs()
          << "BOLT-INFO: --function-order specified without "
          << "--reorder-functions, defaulting to --reorder-functions=user\n";
    } else if (opts::ReorderFunctions == RT_NONE) {
      BC.errs() << "BOLT-WARNING: --reorder-functions=none is incompatible "
                << "with --function-order, resetting to "
                << "--reorder-functions=user\n";
      opts::ReorderFunctions = RT_USER;
    } else if (opts::ReorderFunctions != RT_USER) {
      StringRef AlgName;
      switch (opts::ReorderFunctions) {
      case RT_EXEC_COUNT:
        AlgName = "exec-count";
        break;
      case RT_HFSORT:
        AlgName = "hfsort";
        break;
      case RT_CDSORT:
        AlgName = "cdsort";
        break;
      case RT_PETTIS_HANSEN:
        AlgName = "pettis-hansen";
        break;
      case RT_RANDOM:
        AlgName = "random";
        break;
      default:
        llvm_unreachable("unexpected reorder type in hybrid mode");
      }
      BC.outs() << "BOLT-INFO: hybrid mode: functions from order file will be "
                << "pinned first, remaining functions ordered by " << AlgName
                << "\n";
    }
  }

  // Process order file if provided. Assign indices 0..N-1 to listed functions.
  // For algorithmic modes, the algorithm orders remaining functions starting
  // at index N. For RT_USER, remaining functions keep original order.
  // UserFileEndIndex tracks the number of functions pinned by the order file.
  uint32_t UserFileEndIndex = 0;
  DenseSet<const BinaryFunction *> UserOrderedFuncs;

  if (!opts::FunctionOrderFile.empty()) {
    Expected<uint32_t> NextIndexOrErr =
        assignFunctionOrder(BC, BFs, 0, &UserOrderedFuncs);
    if (!NextIndexOrErr)
      return NextIndexOrErr.takeError();
    UserFileEndIndex = *NextIndexOrErr;

    BC.outs() << "BOLT-INFO: " << UserFileEndIndex
              << " functions pinned by order file, remaining functions will be "
              << "ordered by algorithm\n";
  }

  // Build call graph (needed for clustering algorithms).
  // Exclude functions already ordered by the user order file.
  if (opts::ReorderFunctions != RT_NONE &&
      opts::ReorderFunctions != RT_EXEC_COUNT &&
      opts::ReorderFunctions != RT_USER) {
    Cg = buildCallGraph(
        BC,
        [&UserOrderedFuncs](const BinaryFunction &BF) {
          if (!BF.hasProfile())
            return true;
          if (BF.getState() != BinaryFunction::State::CFG)
            return true;
          if (UserOrderedFuncs.contains(&BF))
            return true;
          return false;
        },
        opts::CgFromPerfData,
        /*IncludeSplitCalls=*/false, opts::ReorderFunctionsUseHotSize,
        opts::CgUseSplitHotSize, opts::UseEdgeCounts,
        opts::CgIgnoreRecursiveCalls);
    Cg.normalizeArcWeights();
  }

  // Run selected algorithm on remaining functions.
  std::vector<Cluster> Clusters;

  switch (opts::ReorderFunctions) {
  case RT_NONE:
    break;
  case RT_EXEC_COUNT: {
    BinaryFunctionListType SortedFunctions(BFs.size());
    llvm::transform(llvm::make_second_range(BFs), SortedFunctions.begin(),
                    [](BinaryFunction &BF) { return &BF; });
    llvm::stable_sort(
        SortedFunctions, [&](const BinaryFunction *A, const BinaryFunction *B) {
          if (A->isIgnored())
            return false;
          if (B->isIgnored())
            return true;
          const size_t PadA =
              opts::padFunctionBefore(*A) + opts::padFunctionAfter(*A);
          const size_t PadB =
              opts::padFunctionBefore(*B) + opts::padFunctionAfter(*B);
          if (!PadA || !PadB) {
            if (PadA)
              return true;
            if (PadB)
              return false;
          }
          if (!A->hasProfile())
            return false;
          if (!B->hasProfile())
            return true;
          return A->getExecutionCount() > B->getExecutionCount();
        });
    uint32_t Index = UserFileEndIndex;
    for (BinaryFunction *BF : SortedFunctions)
      if (BF->hasProfile() && !BF->hasValidIndex()) {
        BF->setIndex(Index++);
        LLVM_DEBUG(if (opts::Verbosity > 1) {
          dbgs() << "BOLT-INFO: hot func " << BF->getPrintName() << " ("
                 << BF->getExecutionCount() << ")\n";
        });
      }
  } break;
  case RT_HFSORT:
    Clusters = clusterize(Cg);
    break;
  case RT_CDSORT: {
    // It is required that the sum of incoming arc weights is not greater
    // than the number of samples for every function. Ensuring the call graph
    // obeys the property before running the algorithm.
    Cg.adjustArcWeights();

    // Initialize CFG nodes and their data
    std::vector<uint64_t> FuncSizes;
    std::vector<uint64_t> FuncCounts;
    std::vector<codelayout::EdgeCount> CallCounts;
    std::vector<uint64_t> CallOffsets;
    for (NodeId F = 0; F < Cg.numNodes(); ++F) {
      FuncSizes.push_back(Cg.size(F));
      FuncCounts.push_back(Cg.samples(F));
      for (NodeId Succ : Cg.successors(F)) {
        const Arc &Arc = *Cg.findArc(F, Succ);
        CallCounts.push_back({F, Succ, uint64_t(Arc.weight())});
        CallOffsets.push_back(uint64_t(Arc.avgCallOffset()));
      }
    }

    // Run the layout algorithm.
    std::vector<uint64_t> Result = codelayout::computeCacheDirectedLayout(
        FuncSizes, FuncCounts, CallCounts, CallOffsets);

    // Create a single cluster from the computed order of hot functions.
    std::vector<CallGraph::NodeId> NodeOrder(Result.begin(), Result.end());
    Clusters.emplace_back(Cluster(NodeOrder, Cg));
  } break;
  case RT_PETTIS_HANSEN:
    Clusters = pettisAndHansen(Cg);
    break;
  case RT_RANDOM:
    std::srand(opts::RandomSeed);
    Clusters = randomClusters(Cg);
    break;
  case RT_USER:
    // Order file already processed above; nothing more to do.
    break;
  default:
    llvm_unreachable("unexpected layout type");
  }

  reorder(BC, std::move(Clusters), BFs, UserFileEndIndex);

  if (!BC.RISCVFarDataEarlyFunctions.empty()) {
    BinaryFunctionListType OrderedFunctions;
    for (BinaryFunction &BF : llvm::make_second_range(BFs))
      if (BC.shouldEmit(BF))
        OrderedFunctions.push_back(&BF);
    llvm::stable_sort(OrderedFunctions, compareBinaryFunctionByIndex);
    auto IsEarly = [&BC](const BinaryFunction *BF) {
      return BC.RISCVFarDataEarlyFunctions.contains(BF);
    };
    const bool ChangesOrder = !std::is_partitioned(
        OrderedFunctions.begin(), OrderedFunctions.end(), IsEarly);
    const bool ChangesUserOrder =
        ChangesOrder && llvm::any_of(OrderedFunctions, [&](BinaryFunction *BF) {
          return UserOrderedFuncs.contains(BF) && !IsEarly(BF);
        });
    const auto EarlyEnd = std::stable_partition(
        OrderedFunctions.begin(), OrderedFunctions.end(), IsEarly);
    uint32_t Index = 0;
    for (BinaryFunction *BF : OrderedFunctions) {
      BF->clearIndex();
      BF->setIndex(Index++);
    }
    BC.outs() << "BOLT-INFO: RISC-V far-data placement: "
              << std::distance(OrderedFunctions.begin(), EarlyEnd)
              << " functions placed before remaining emitted functions\n";
    if (ChangesUserOrder)
      BC.errs() << "BOLT-WARNING: RISC-V far-data placement changes the "
                   "requested function order; relative order within each "
                   "group is preserved\n";
  }

  BC.HasFinalizedFunctionOrder = true;

  std::unique_ptr<std::ofstream> FuncsFile;
  if (!opts::GenerateFunctionOrderFile.empty()) {
    FuncsFile = std::make_unique<std::ofstream>(opts::GenerateFunctionOrderFile,
                                                std::ios::out);
    if (!FuncsFile) {
      BC.errs() << "BOLT-ERROR: ordered functions file "
                << opts::GenerateFunctionOrderFile << " cannot be opened\n";
      return createFatalBOLTError("");
    }
  }

  std::unique_ptr<std::ofstream> LinkSectionsFile;
  if (!opts::LinkSectionsFile.empty()) {
    LinkSectionsFile =
        std::make_unique<std::ofstream>(opts::LinkSectionsFile, std::ios::out);
    if (!LinkSectionsFile) {
      BC.errs() << "BOLT-ERROR: link sections file " << opts::LinkSectionsFile
                << " cannot be opened\n";
      return createFatalBOLTError("");
    }
  }

  if (FuncsFile || LinkSectionsFile) {
    BinaryFunctionListType SortedFunctions(BFs.size());
    llvm::transform(llvm::make_second_range(BFs), SortedFunctions.begin(),
                    [](BinaryFunction &BF) { return &BF; });

    // Sort functions by index.
    llvm::stable_sort(SortedFunctions, compareBinaryFunctionByIndex);

    for (const BinaryFunction *Func : SortedFunctions) {
      if (!Func->hasValidIndex())
        break;
      if (Func->isPLTFunction())
        continue;

      if (FuncsFile)
        *FuncsFile << Func->getOneName().str() << '\n';

      if (LinkSectionsFile) {
        const char *Indent = "";
        std::vector<StringRef> AllNames = Func->getNames();
        llvm::sort(AllNames);
        for (StringRef Name : AllNames) {
          const size_t SlashPos = Name.find('/');
          if (SlashPos != std::string::npos) {
            // Avoid duplicates for local functions.
            if (Name.find('/', SlashPos + 1) != std::string::npos)
              continue;
            Name = Name.substr(0, SlashPos);
          }
          *LinkSectionsFile << Indent << ".text." << Name.str() << '\n';
          Indent = " ";
        }
      }
    }

    if (FuncsFile) {
      FuncsFile->close();
      BC.outs() << "BOLT-INFO: dumped function order to "
                << opts::GenerateFunctionOrderFile << '\n';
    }

    if (LinkSectionsFile) {
      LinkSectionsFile->close();
      BC.outs() << "BOLT-INFO: dumped linker section order to "
                << opts::LinkSectionsFile << '\n';
    }
  }
  return Error::success();
}

} // namespace bolt
} // namespace llvm
