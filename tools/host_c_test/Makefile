# Host-side bit-exact tests for Step 3b integer ops.
# Compiles tools/host_c_test/host_main.c together with the firmware
# implementation in lecture2_0420_release/test1/application/w4a8_ops.c
# using the system gcc (NOT riscv-nuclei-elf-gcc) so we can run it locally.

CC      ?= gcc
CFLAGS  := -std=c11 -O0 -g -Wall -Wextra -Wno-unused-parameter -Wno-unused-function
FW_DIR  := ../../lecture2_0420_release/test1/application
INC     := -I$(FW_DIR) -I.

SRCS := host_main.c $(FW_DIR)/w4a8_ops.c
BIN  := host_test

GOLDEN := golden.bin

.PHONY: all test clean regen

all: $(BIN)

$(BIN): $(SRCS) $(FW_DIR)/w4a8_ops.h
	$(CC) $(CFLAGS) $(INC) $(SRCS) -o $(BIN)

test: $(BIN) $(GOLDEN)
	./$(BIN) $(GOLDEN)

# Regenerate the golden blob via the Python pipeline.
regen:
	cd ../.. && python tools/w4a8_block_full.py

clean:
	rm -f $(BIN) $(BIN).exe
