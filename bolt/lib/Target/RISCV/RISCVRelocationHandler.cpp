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

bool RISCVRelocationHandler::canEncodeValue(uint32_t Type, uint64_t Value,
                                            uint64_t PC) const {
  switch (Type) {
  default:
    llvm_unreachable("unsupported relocation");
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
    return true;
  }
}

uint64_t RISCVRelocationHandler::encodeValue(uint32_t Type, uint64_t Value,
                                             uint64_t PC,
                                             uint32_t OriginalInst) const {
  auto encodePCRel = [&](uint32_t Type, uint64_t Value) -> uint64_t {
    const int64_t PCRelValue =
        static_cast<int64_t>(Value) - static_cast<int64_t>(PC);
    assert((PCRelValue & 0x1) == 0 && "RISC-V branch target is misaligned");
    const uint64_t EncValue = static_cast<uint64_t>(PCRelValue);
    switch (Type) {
    default:
      llvm_unreachable("unsupported relocation");
    case ELF::R_RISCV_BRANCH: {
      assert(isInt<13>(PCRelValue) && "RISC-V branch target out of range");
      const uint64_t Sbit = (EncValue >> 12) & 0x1;
      const uint64_t Hi1 = (EncValue >> 11) & 0x1;
      const uint64_t Mid6 = (EncValue >> 5) & 0x3f;
      const uint64_t Lo4 = (EncValue >> 1) & 0xf;
      return (OriginalInst & 0x01fff07f) | (Sbit << 31) | (Mid6 << 25) |
             (Lo4 << 8) | (Hi1 << 7);
    }
    case ELF::R_RISCV_JAL: {
      assert(isInt<21>(PCRelValue) && "RISC-V jump target out of range");
      const uint64_t Sbit = (EncValue >> 20) & 0x1;
      const uint64_t Hi8 = (EncValue >> 12) & 0xff;
      const uint64_t Mid1 = (EncValue >> 11) & 0x1;
      const uint64_t Lo10 = (EncValue >> 1) & 0x3ff;
      return (OriginalInst & 0xfff) | (Sbit << 31) | (Lo10 << 21) | (Mid1 << 20) |
             (Hi8 << 12);
    }
    case ELF::R_RISCV_RVC_BRANCH: {
      assert(isInt<9>(PCRelValue) &&
             "RISC-V compressed branch target out of range");
      const uint64_t Bit8 = (EncValue >> 8) & 0x1;
      const uint64_t Bit7_6 = (EncValue >> 6) & 0x3;
      const uint64_t Bit5 = (EncValue >> 5) & 0x1;
      const uint64_t Bit4_3 = (EncValue >> 3) & 0x3;
      const uint64_t Bit2_1 = (EncValue >> 1) & 0x3;
      return (OriginalInst & 0xe383) | (Bit8 << 12) | (Bit4_3 << 10) |
             (Bit7_6 << 5) | (Bit2_1 << 3) | (Bit5 << 2);
    }
    case ELF::R_RISCV_RVC_JUMP: {
      assert(isInt<12>(PCRelValue) &&
             "RISC-V compressed jump target out of range");
      const uint64_t Bit11 = (EncValue >> 11) & 0x1;
      const uint64_t Bit4 = (EncValue >> 4) & 0x1;
      const uint64_t Bit9_8 = (EncValue >> 8) & 0x3;
      const uint64_t Bit10 = (EncValue >> 10) & 0x1;
      const uint64_t Bit6 = (EncValue >> 6) & 0x1;
      const uint64_t Bit7 = (EncValue >> 7) & 0x1;
      const uint64_t Bit3_1 = (EncValue >> 1) & 0x7;
      const uint64_t Bit5 = (EncValue >> 5) & 0x1;
      return (OriginalInst & 0xe003) | (Bit11 << 12) | (Bit4 << 11) |
             (Bit9_8 << 9) | (Bit10 << 8) | (Bit6 << 7) | (Bit7 << 6) |
             (Bit3_1 << 3) | (Bit5 << 2);
    }
    }
  };

  switch (Type) {
  default:
    llvm_unreachable("unsupported relocation");
  case ELF::R_RISCV_32:
  case ELF::R_RISCV_64:
    break;
  case ELF::R_RISCV_BRANCH:
  case ELF::R_RISCV_JAL:
  case ELF::R_RISCV_RVC_BRANCH:
  case ELF::R_RISCV_RVC_JUMP:
    return encodePCRel(Type, Value);
  }
  return Value;
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
