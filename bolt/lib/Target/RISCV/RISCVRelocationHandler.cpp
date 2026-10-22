//===- RISCVRelocationHandler.cpp - RISC-V relocation handling -----------===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements the RISCV relocation handler.
//
//===----------------------------------------------------------------------===//

#include "bolt/Core/Relocation.h"
#include "llvm/Object/ELF.h"
#include "llvm/Support/Endian.h"
#include "llvm/Support/ErrorHandling.h"
#include "llvm/Support/MathExtras.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;
using namespace bolt;

namespace ELFReserved {
enum {
  R_RISCV_TPREL_I = 49,
  R_RISCV_TPREL_S = 50,
};
} // namespace ELFReserved

namespace {

class RISCVRelocationHandler final : public RelocationHandler {
  bool Is64Bit;

public:
  explicit RISCVRelocationHandler(bool Is64Bit) : Is64Bit(Is64Bit) {}

  bool isSupported(uint32_t Type) const override;
  size_t getSizeForType(uint32_t Type) const override;
  bool skipRelocationType(uint32_t Type) const override;

  uint64_t encodeValue(uint32_t Type, uint64_t Value, uint64_t PC,
                       uint32_t OriginalInst) const override;
  bool isInstructionRelocation(uint32_t Type) const override;
  void applyInstructionRelocation(MutableArrayRef<char> Data, uint32_t Type,
                                  uint64_t Value, uint64_t PC) const override;
  bool canEncodeValue(uint32_t Type, uint64_t Value,
                      uint64_t PC) const override;
  uint64_t extractValue(uint32_t Type, uint64_t Contents,
                        uint64_t PC) const override;

  bool isGOT(uint32_t Type) const override;
  bool isRelative(uint32_t Type) const override;
  bool isIRelative(uint32_t Type) const override;
  bool isTLS(uint32_t Type) const override;
  bool isInstructionReference(uint32_t Type) const override;
  bool isPCRelative(uint32_t Type) const override;

  uint32_t getNone() const override;
  uint32_t getPC32() const override;
  uint32_t getPC64() const override;
  uint32_t getAbs32() const override;
  uint32_t getAbs64() const override;
  uint32_t getRelative() const override;

  MCBinaryExpr::Opcode getComposeOpcodeFor(uint32_t Type) const override;
  void printType(raw_ostream &OS, uint32_t Type) const override;
};

} // namespace

bool RISCVRelocationHandler::isRelative(uint32_t Type) const {
  return Type == ELF::R_RISCV_RELATIVE;
}

bool RISCVRelocationHandler::isIRelative(uint32_t Type) const {
  if (!Is64Bit)
    llvm_unreachable("not implemented");
  return Type == ELF::R_RISCV_IRELATIVE;
}

bool RISCVRelocationHandler::isInstructionReference(uint32_t Type) const {
  return Type == ELF::R_RISCV_PCREL_LO12_I || Type == ELF::R_RISCV_PCREL_LO12_S;
}

uint32_t RISCVRelocationHandler::getNone() const { return ELF::R_RISCV_NONE; }

uint32_t RISCVRelocationHandler::getPC32() const {
  return ELF::R_RISCV_32_PCREL;
}

uint32_t RISCVRelocationHandler::getPC64() const {
  llvm_unreachable("not implemented");
}

uint32_t RISCVRelocationHandler::getAbs32() const {
  return ELF::R_RISCV_32;
}

uint32_t RISCVRelocationHandler::getAbs64() const { return ELF::R_RISCV_64; }

uint32_t RISCVRelocationHandler::getRelative() const {
  if (!Is64Bit)
    llvm_unreachable("not implemented");
  return ELF::R_RISCV_RELATIVE;
}

MCBinaryExpr::Opcode
RISCVRelocationHandler::getComposeOpcodeFor(uint32_t Type) const {
  switch (Type) {
  default:
    llvm_unreachable("not implemented");
  case ELF::R_RISCV_ADD32:
    return MCBinaryExpr::Add;
  case ELF::R_RISCV_SUB32:
    return MCBinaryExpr::Sub;
  }
}

void RISCVRelocationHandler::printType(raw_ostream &OS, uint32_t Type) const {
  OS << object::getELFRelocationTypeName(ELF::EM_RISCV, Type);
}

bool RISCVRelocationHandler::isSupported(uint32_t Type) const {
  switch (Type) {
  default:
    return false;
  case ELF::R_RISCV_JAL:
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
  case ELF::R_RISCV_BRANCH:
  case ELF::R_RISCV_RELAX:
  case ELF::R_RISCV_GOT_HI20:
  case ELF::R_RISCV_PCREL_HI20:
  case ELF::R_RISCV_PCREL_LO12_I:
  case ELF::R_RISCV_PCREL_LO12_S:
  case ELF::R_RISCV_RVC_JUMP:
  case ELF::R_RISCV_RVC_BRANCH:
  case ELF::R_RISCV_ADD32:
  case ELF::R_RISCV_SUB32:
  case ELF::R_RISCV_HI20:
  case ELF::R_RISCV_LO12_I:
  case ELF::R_RISCV_LO12_S:
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
  case ELF::R_RISCV_TLS_GOT_HI20:
  case ELF::R_RISCV_TLS_GD_HI20:
  case ELF::R_RISCV_TPREL_HI20:
  case ELF::R_RISCV_TPREL_ADD:
  case ELF::R_RISCV_TPREL_LO12_I:
  case ELF::R_RISCV_TPREL_LO12_S:
  case ELFReserved::R_RISCV_TPREL_I:
  case ELFReserved::R_RISCV_TPREL_S:
    return true;
  }
}

size_t RISCVRelocationHandler::getSizeForType(uint32_t Type) const {
  switch (Type) {
  default:
    errs() << object::getELFRelocationTypeName(ELF::EM_RISCV, Type) << '\n';
    llvm_unreachable("unsupported relocation type");
  case ELF::R_RISCV_RVC_JUMP:
  case ELF::R_RISCV_RVC_BRANCH:
    return 2;
  case ELF::R_RISCV_JAL:
  case ELF::R_RISCV_BRANCH:
  case ELF::R_RISCV_PCREL_HI20:
  case ELF::R_RISCV_PCREL_LO12_I:
  case ELF::R_RISCV_PCREL_LO12_S:
  case ELF::R_RISCV_32_PCREL:
  case ELF::R_RISCV_ADD32:
  case ELF::R_RISCV_SUB32:
  case ELF::R_RISCV_HI20:
  case ELF::R_RISCV_LO12_I:
  case ELF::R_RISCV_LO12_S:
  case ELF::R_RISCV_32:
    return 4;
  case ELF::R_RISCV_64:
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
  case ELF::R_RISCV_GOT_HI20:
  case ELF::R_RISCV_TLS_GOT_HI20:
  case ELF::R_RISCV_TLS_GD_HI20:
    // See extractValue for why this is necessary.
    return 8;
  }
}

bool RISCVRelocationHandler::skipRelocationType(uint32_t Type) const {
  switch (Type) {
  default:
    return false;
  case ELF::R_RISCV_NONE:
  case ELF::R_RISCV_RELAX:
  case ELF::R_RISCV_ALIGN:
    return true;
  }
}

bool RISCVRelocationHandler::isInstructionRelocation(uint32_t Type) const {
  switch (Type) {
  default:
    return false;
  case ELF::R_RISCV_BRANCH:
  case ELF::R_RISCV_JAL:
  case ELF::R_RISCV_RVC_BRANCH:
  case ELF::R_RISCV_RVC_JUMP:
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
    return true;
  }
}

bool RISCVRelocationHandler::canEncodeValue(uint32_t Type, uint64_t Value,
                                            uint64_t PC) const {
  // PC-relative arithmetic wraps at XLEN, including branches across address 0.
  const int64_t Offset = !Is64Bit ? SignExtend64<32>(Value - PC) : Value - PC;
  switch (Type) {
  default:
    llvm_unreachable("unsupported relocation");
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
    return true;
  case ELF::R_RISCV_BRANCH:
    return !(Offset & 1) && isInt<13>(Offset);
  case ELF::R_RISCV_JAL:
    return !(Offset & 1) && isInt<21>(Offset);
  case ELF::R_RISCV_RVC_BRANCH:
    return !(Offset & 1) && isInt<9>(Offset);
  case ELF::R_RISCV_RVC_JUMP:
    return !(Offset & 1) && isInt<12>(Offset);
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
    // AUIPC/JALR can reach any aligned address in the RV32 address space.
    if (!Is64Bit)
      return !(Offset & 1);
    // Account for the carry from the signed low immediate. In RV64 the
    // rounded high part must still fit the sign-extended AUIPC immediate.
    return !(Offset & 1) && Offset >= INT64_C(-2147485696) &&
           Offset <= INT64_C(2147481599);
  }
}

void RISCVRelocationHandler::applyInstructionRelocation(
    MutableArrayRef<char> Data, uint32_t Type, uint64_t Value,
    uint64_t PC) const {
  assert(isInstructionRelocation(Type) &&
         "expected a RISC-V control-flow relocation");
  assert(Data.size() == getSizeForType(Type) &&
         "unexpected RISC-V instruction buffer size");
  if (!canEncodeValue(Type, Value, PC))
    report_fatal_error("fixed RISC-V reference exceeds its encoding range");

  auto Patch16 = [](char *Location, uint16_t Immediate, uint16_t Mask) {
    const uint16_t Inst = support::endian::read16le(Location);
    support::endian::write16le(Location, (Inst & ~Mask) | Immediate);
  };
  auto Patch32 = [](char *Location, uint32_t Immediate, uint32_t Mask) {
    const uint32_t Inst = support::endian::read32le(Location);
    support::endian::write32le(Location, (Inst & ~Mask) | Immediate);
  };

  const uint64_t Offset = Value - PC;
  switch (Type) {
  default:
    llvm_unreachable("unsupported RISC-V control-flow relocation");
  case ELF::R_RISCV_BRANCH:
    Patch32(Data.data(),
            ((Offset & 0x1000) << 19) | ((Offset & 0x7e0) << 20) |
                ((Offset & 0x1e) << 7) | ((Offset & 0x800) >> 4),
            0xfe000f80);
    return;
  case ELF::R_RISCV_JAL:
    Patch32(Data.data(),
            ((Offset & 0x100000) << 11) | ((Offset & 0x7fe) << 20) |
                ((Offset & 0x800) << 9) | (Offset & 0xff000),
            0xfffff000);
    return;
  case ELF::R_RISCV_RVC_BRANCH:
    Patch16(Data.data(),
            ((Offset & 0x100) << 4) | ((Offset & 0x18) << 7) |
                ((Offset & 0xc0) >> 1) | ((Offset & 0x6) << 2) |
                ((Offset & 0x20) >> 3),
            0x1c7c);
    return;
  case ELF::R_RISCV_RVC_JUMP:
    Patch16(Data.data(),
            ((Offset & 0x800) << 1) | ((Offset & 0x10) << 7) |
                ((Offset & 0x300) << 1) | ((Offset & 0x400) >> 2) |
                ((Offset & 0x40) << 1) | ((Offset & 0x80) >> 1) |
                ((Offset & 0xe) << 2) | ((Offset & 0x20) >> 3),
            0x1ffc);
    return;
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
    // Update AUIPC and JALR separately, preserving both instructions' register
    // operands. Round the high part to account for the signed low immediate.
    Patch32(Data.data(), (Offset + 0x800) & 0xfffff000, 0xfffff000);
    Patch32(Data.data() + 4, (Offset & 0xfff) << 20, 0xfff00000);
    return;
  }
}

uint64_t RISCVRelocationHandler::encodeValue(uint32_t Type, uint64_t Value,
                                             uint64_t PC,
                                             uint32_t OriginalInst) const {
  if (isInstructionRelocation(Type) && getSizeForType(Type) <= 4) {
    char Data[4];
    support::endian::write32le(Data, OriginalInst);
    applyInstructionRelocation(
        MutableArrayRef<char>(Data, getSizeForType(Type)), Type, Value, PC);
    return getSizeForType(Type) == 2 ? support::endian::read16le(Data)
                                     : support::endian::read32le(Data);
  }
  switch (Type) {
  default:
    llvm_unreachable("unsupported relocation");
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
    return Value;
  }
}

static uint64_t extractUImmRISCV(uint32_t Contents) {
  return SignExtend64<32>(Contents & 0xfffff000);
}

static uint64_t extractIImmRISCV(uint32_t Contents) {
  return SignExtend64<12>(Contents >> 20);
}

static uint64_t extractSImmRISCV(uint32_t Contents) {
  return SignExtend64<12>(((Contents >> 7) & 0x1f) | ((Contents >> 25) << 5));
}

static uint64_t extractJImmRISCV(uint32_t Contents) {
  return SignExtend64<21>(
      (((Contents >> 21) & 0x3ff) << 1) | (((Contents >> 20) & 0x1) << 11) |
      (((Contents >> 12) & 0xff) << 12) | (((Contents >> 31) & 0x1) << 20));
}

static uint64_t extractBImmRISCV(uint32_t Contents) {
  return SignExtend64<13>(
      (((Contents >> 8) & 0xf) << 1) | (((Contents >> 25) & 0x3f) << 5) |
      (((Contents >> 7) & 0x1) << 11) | (((Contents >> 31) & 0x1) << 12));
}

uint64_t RISCVRelocationHandler::extractValue(uint32_t Type, uint64_t Contents,
                                              uint64_t PC) const {
  switch (Type) {
  default:
    errs() << object::getELFRelocationTypeName(ELF::EM_RISCV, Type) << '\n';
    llvm_unreachable("unsupported relocation type");
  case ELF::R_RISCV_JAL:
    return extractJImmRISCV(Contents);
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
    // The psABI "Relocations" chapter's "Procedure Calls" section defines
    // R_RISCV_CALL and R_RISCV_CALL_PLT over an AUIPC/JALR pair. Decode both
    // instructions so the addend includes the low 12 bits carried by JALR.
    return extractUImmRISCV(Contents & 0xffffffff) +
           extractIImmRISCV(Contents >> 32);
  case ELF::R_RISCV_BRANCH:
    return extractBImmRISCV(Contents);
  case ELF::R_RISCV_GOT_HI20:
  case ELF::R_RISCV_TLS_GOT_HI20:
  case ELF::R_RISCV_TLS_GD_HI20:
    // We need to know the exact address of the GOT entry so we extract the
    // value from both the AUIPC and L[D|W]. We cannot rely on the symbol in the
    // relocation for this since it simply refers to the object that is stored
    // in the GOT entry, not to the entry itself.
    return extractUImmRISCV(Contents & 0xffffffff) +
           extractIImmRISCV(Contents >> 32);
  case ELF::R_RISCV_PCREL_HI20:
  case ELF::R_RISCV_HI20:
    return extractUImmRISCV(Contents);
  case ELF::R_RISCV_PCREL_LO12_I:
  case ELF::R_RISCV_LO12_I:
    return extractIImmRISCV(Contents);
  case ELF::R_RISCV_PCREL_LO12_S:
  case ELF::R_RISCV_LO12_S:
    return extractSImmRISCV(Contents);
  case ELF::R_RISCV_RVC_JUMP:
    return SignExtend64<11>(Contents >> 2);
  case ELF::R_RISCV_RVC_BRANCH:
    return SignExtend64<8>(((Contents >> 2) & 0x1f) | ((Contents >> 5) & 0xe0));
  case ELF::R_RISCV_ADD32:
  case ELF::R_RISCV_SUB32:
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
    return Contents;
  }
}

bool RISCVRelocationHandler::isGOT(uint32_t Type) const {
  switch (Type) {
  default:
    return false;
  case ELF::R_RISCV_GOT_HI20:
  case ELF::R_RISCV_TLS_GOT_HI20:
  case ELF::R_RISCV_TLS_GD_HI20:
    return true;
  }
}

bool RISCVRelocationHandler::isTLS(uint32_t Type) const {
  switch (Type) {
  default:
    return false;
  case ELF::R_RISCV_TLS_GOT_HI20:
  case ELF::R_RISCV_TLS_GD_HI20:
  case ELF::R_RISCV_TPREL_HI20:
  case ELF::R_RISCV_TPREL_ADD:
  case ELF::R_RISCV_TPREL_LO12_I:
  case ELF::R_RISCV_TPREL_LO12_S:
  case ELFReserved::R_RISCV_TPREL_I:
  case ELFReserved::R_RISCV_TPREL_S:
    return true;
  }
}

bool RISCVRelocationHandler::isPCRelative(uint32_t Type) const {
  switch (Type) {
  default:
    llvm_unreachable("Unknown relocation type");
  case ELF::R_RISCV_ADD32:
  case ELF::R_RISCV_SUB32:
  case ELF::R_RISCV_HI20:
  case ELF::R_RISCV_LO12_I:
  case ELF::R_RISCV_LO12_S:
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
    return false;
  case ELF::R_RISCV_JAL:
  case ELF::R_RISCV_CALL:
  case ELF::R_RISCV_CALL_PLT:
  case ELF::R_RISCV_BRANCH:
  case ELF::R_RISCV_GOT_HI20:
  case ELF::R_RISCV_PCREL_HI20:
  case ELF::R_RISCV_PCREL_LO12_I:
  case ELF::R_RISCV_PCREL_LO12_S:
  case ELF::R_RISCV_RVC_JUMP:
  case ELF::R_RISCV_RVC_BRANCH:
  case ELF::R_RISCV_32_PCREL:
  case ELF::R_RISCV_TLS_GOT_HI20:
  case ELF::R_RISCV_TLS_GD_HI20:
    return true;
  }
}

namespace llvm::bolt {

std::unique_ptr<RelocationHandler> createRISCVRelocationHandler(bool Is64Bit) {
  return std::make_unique<RISCVRelocationHandler>(Is64Bit);
}

} // namespace llvm::bolt
