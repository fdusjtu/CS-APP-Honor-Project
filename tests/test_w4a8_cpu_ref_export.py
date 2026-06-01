import random
import unittest

from tools import w4a8_common as common
from tools import w4a8_cpu_ref_export as cpu_ref
from tools import w4a8_engine_vectors as eng


class RowMajorPackingTests(unittest.TestCase):
    """Validates the CPU baseline's row-major INT4 byte layout."""

    def test_pack_unpack_round_trip_random(self):
        rng = random.Random(0xC0FFEE)
        for trial in range(8):
            M = rng.choice([16, 64, 128])
            N = rng.choice([64, 128, 256])
            W = [[rng.randint(-8, 7) for _ in range(N)] for _ in range(M)]
            packed = cpu_ref.pack_int4_row_major(W)
            self.assertEqual(len(packed), M * N // 2)
            unpacked = cpu_ref.unpack_int4_row_major(packed, M, N)
            self.assertEqual(unpacked, W, f"trial {trial} M={M} N={N}")

    def test_pack_byte_layout_low_then_high_nibble(self):
        # row 0: [-1, 7, -8, 0, ...] -> bytes: 0x7f, 0x08, ...
        W = [[-1, 7, -8, 0]]
        packed = cpu_ref.pack_int4_row_major(W)
        self.assertEqual(packed, [(0xF) | (0x7 << 4), (0x8) | (0x0 << 4)])

    def test_odd_N_rejected(self):
        with self.assertRaises(ValueError):
            cpu_ref.pack_int4_row_major([[1, 2, 3]])


def _ref_cpu_gemv(W_q, x, scale, shift):
    """Pure-Python mirror of w4a8_cpu_ref.c logic, packed-then-unpacked."""
    M = len(W_q)
    N = len(W_q[0])
    packed = cpu_ref.pack_int4_row_major(W_q)
    W_back = cpu_ref.unpack_int4_row_major(packed, M, N)
    y = []
    for r in range(M):
        acc = sum(W_back[r][c] * x[c] for c in range(N))
        y.append((acc * scale[r]) >> shift)
    return y


class CpuFormatMatchesEngineGoldenTests(unittest.TestCase):
    """The CPU layout must produce the same y as golden_linear, layer by layer."""

    def test_synthetic_target_layers(self):
        vec = eng.build_vectors(eng.TARGET_CONFIG, seed=1, weights=None)
        for case in vec["cases"]:
            with self.subTest(layer=case["name"]):
                y_cpu = _ref_cpu_gemv(
                    case["W_q"], case["x"], case["scale_q"], common.DEFAULT_SHIFT
                )
                self.assertEqual(y_cpu, case["y"])

    def test_default_rep_layers_present(self):
        vec = eng.build_vectors(eng.TARGET_CONFIG, seed=1, weights=None)
        names = {c["name"] for c in vec["cases"]}
        for n in cpu_ref.DEFAULT_REP_LAYERS:
            self.assertIn(n, names)


if __name__ == "__main__":
    unittest.main()
