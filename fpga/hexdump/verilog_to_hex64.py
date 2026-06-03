"""
Convert a RISC-V .verilog memory image (byte-per-token format) to a 64-bit
little-endian hex file suitable for Vivado $readmemh into a 64-bit wide SRAM.

The .verilog format (objcopy -O verilog) uses `@ADDR` lines to mark the start
address of each following byte block. Sections are NOT contiguous: e.g. .init
may end at a non-4-aligned address and .text restarts at a padded address via a
new `@ADDR`. We MUST honor those address markers and place bytes at their
absolute offsets (filling gaps with 0x00); otherwise the image is shifted and
every PC-relative address computation breaks (observed: a 2-byte shift turned an
aligned store into a misaligned-store trap at boot).

Usage:
    python verilog_to_hex64.py input.verilog output.hex
"""
import sys

def convert(input_file, output_file):
    base = None          # address that maps to output offset 0
    cur = 0              # current write offset (relative to base)
    mem = {}             # offset -> byte token (hex string)

    with open(input_file, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('@'):
                addr = int(line[1:], 16)
                if base is None:
                    base = addr
                cur = addr - base
                continue
            for token in line.split():
                mem[cur] = token
                cur += 1

    if not mem:
        print("WARNING: no bytes parsed from input")
        size = 0
    else:
        size = max(mem) + 1
    # pad up to a multiple of 8 bytes (one 64-bit word)
    size = (size + 7) & ~7

    with open(output_file, 'w') as f:
        for i in range(0, size, 8):
            # gaps (unmapped offsets) are filled with 00
            chunk = [mem.get(i + j, '00') for j in range(8)]
            # Reverse byte order: byte[7]..byte[0] gives the big-endian repr of
            # the little-endian 64-bit word, which is what $readmemh expects for
            # a 64-bit memory (MSB first in the hex string).
            word = ''.join(reversed(chunk))
            f.write(word + '\n')

    print(f"Converted bytes (base=0x{(base or 0):08x}, span={size}) -> {size // 8} 64-bit words")
    print(f"Output: {output_file}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print("Usage: python verilog_to_hex64.py input.verilog output.hex")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
