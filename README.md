![](../../workflows/gds/badge.svg) ![](../../workflows/docs/badge.svg) ![](../../workflows/test/badge.svg) ![](../../workflows/fpga/badge.svg)

# OLAF-8 -- Bounded-Memory Online Adaptive Fuzzy Inference Engine

Tiny Tapeout submission, SKY130, 1×1 tile

- [Read the full project documentation](docs/info.md)
- [OLAF-8 project repository](https://github.com/Sharf23/opt_OLAF-8)

## What is this?

OLAF-8 is a compact fully digital **Online Learning Adaptive Fuzzy Inference Engine** that performs fuzzy inference using a fixed **8-rule bounded memory** while supporting online rule admission and replacement during operation.

The design accepts two 4-bit input values, generates fuzzy membership values across LOW, MID, and HIGH regions, evaluates the stored fuzzy rules sequentially, and produces a defuzzified output using weighted accumulation and iterative digital division.

The key feature of OLAF-8 is its **bounded online learning mechanism**. When the current input is not sufficiently represented by the existing rule set, a low-utility rule can be replaced with a new rule derived from the current input. This allows the rule base to adapt without increasing the hardware memory size.

The implementation was optimized for ASIC hardware with emphasis on reducing unnecessary logic and hardware resources while preserving the core online-adaptive fuzzy inference functionality.

## Design summary

- **Top module:** `tt_um_olaf8`
- **Rule memory:** 8 fuzzy rules
- **Inputs:** Two 4-bit values
- **Fuzzy regions:** LOW, MID, HIGH
- **Rule evaluation:** Sequential
- **Rule firing:** MIN operation
- **Accumulation:** Weighted fuzzy accumulation
- **Defuzzification:** Iterative digital division
- **Learning:** Online rule admission and replacement
- **Clock:** 10 MHz
- **Technology:** SKY130
- **Tiny Tapeout tile:** 1×1
- **HDL:** Verilog

## What is Tiny Tapeout?

Tiny Tapeout is an educational project that aims to make it easier and cheaper than ever to get digital and analog designs manufactured on a real chip.

To learn more, visit https://tinytapeout.com/.

## Resources

- [OLAF-8 Project Repository](https://github.com/Sharf23/opt_OLAF-8)
- [Project Documentation](docs/info.md)
- [Tiny Tapeout FAQ](https://tinytapeout.com/faq/)
- [Digital design lessons](https://tinytapeout.com/digital_design/)
- [Build your design locally](https://www.tinytapeout.com/guides/local-hardening/)
