# Must Read project_goal.md and tmp.md before contributing to this repository.
# Repository Guidelines

## Project Structure & Module Organization

This repository is a CSAPP honor-course hardware/software bundle for E203 on an FPGA board. Lecture slides and PDFs live at the root and under `lecture1/`. The main release is `lecture2_0420_release/`:

- `fig/`: tutorial Markdown/PDF and referenced images.
- `trans/`: Vivado 2022.2 project (`trans.xpr`), Verilog sources, simulation files, IP, and generated outputs.
- `test1/`: Nuclei Studio RISC-V firmware project. Edit application code mainly in `test1/application/`.
- `test1/hbird_sdk/`: bundled Hummingbird SDK headers, drivers, startup code, and linker scripts.
- `hexdump-2.1.0/`: Windows utility for inspecting binary data.

Avoid moving Vivado or Nuclei project directories casually; project metadata contains path-sensitive settings.

## Build, Test, and Development Commands

- Open FPGA project: launch Vivado 2022.2 and open `lecture2_0420_release/trans/trans.xpr`.
- Build firmware from a configured shell:
  ```powershell
  cd lecture2_0420_release/test1/Debug
  make all
  ```
  This creates `test1.elf`, `test1.hex`, `test1.lst`, and size/map outputs using `riscv-nuclei-elf-*` tools.
- Clean firmware outputs:
  ```powershell
  cd lecture2_0420_release/test1/Debug
  make clean
  ```
- Review generated hex:
  ```powershell
  lecture2_0420_release/hexdump-2.1.0/hexdump.exe -C path/to/file.bin
  ```

## Coding Style & Naming Conventions

Keep C code in the existing K&R-style brace pattern and use 4-space indentation, as in `test1/application/main.c`. Prefer lowercase function names with underscores for new C helpers. For Verilog, preserve existing E203 module and signal names; use `.v` for RTL/testbench files and `.xdc` for constraints. Do not hand-edit generated files under `Debug/`, `trans.runs/`, `trans.gen/`, `trans.cache/`, or `trans.sim/`.

## Testing Guidelines

There is no standalone unit-test framework. Validate firmware by rebuilding `test1/Debug` and checking that ELF/HEX/listing files regenerate cleanly. Validate RTL changes through Vivado simulation using testbenches under `trans/trans.srcs/sim_1/`; then run synthesis/implementation if timing or board behavior may be affected. Record the Vivado version, target part `xczu3eg-sfvc784-1-i`, and any hardware test result in the change notes.

## Commit & Pull Request Guidelines

No Git history is present in this checkout, so no local commit convention can be inferred. Use concise, imperative commit subjects such as `Update UART firmware example` or `Fix E203 simulation testbench`. Pull requests should describe the changed area, list build or Vivado validation performed, mention required tool versions, and include screenshots or waveform captures when board behavior or simulation output changes.

## Security & Configuration Tips

Keep the Vivado project in an all-English path, matching the tutorial guidance. Do not commit machine-local absolute paths, private license files, or unnecessary generated build outputs unless they are intentionally part of the course release.

## Local Xilinx Skill

For Xilinx/AMD FPGA flow tasks in this repository, use the project-local skill at `.codex/skills/xilinx-suite/SKILL.md`. This includes Vivado, Vitis, HLS, PetaLinux, XDC constraints, IP/block design, synthesis, implementation, bitstream, or Xilinx board/debug flow work.

When using that skill, load its referenced files from `.codex/skills/xilinx-suite/references/`. Keep this skill local to this repository; do not reinstall it into global Codex or Claude directories unless explicitly requested.
