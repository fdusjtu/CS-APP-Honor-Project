import tempfile
import unittest
from pathlib import Path

from tools import w4a8_common as common
from tools import w4a8_gen_vectors as w4a8


class W4A8VectorTests(unittest.TestCase):
    def test_pack_int4_round_trips_signed_values(self):
        values = [-8, -7, -1, 0, 1, 6, 7, -2, 3]

        words = common.pack_int4_matrix(values)
        unpacked = common.unpack_int4_words(words, len(values))

        self.assertEqual(unpacked, values)
        self.assertEqual(words[0], 0xE7610F98)
        self.assertEqual(words[1], 0x00000003)

    def test_golden_tile_accumulates_and_rescales(self):
        w = [[0 for _ in range(common.TILE_N)] for _ in range(common.TILE_M)]
        x = [0 for _ in range(common.TILE_N)]
        for col in range(common.TILE_N):
            x[col] = 2 if col % 2 == 0 else -1
        w[0][0] = 3
        w[0][1] = -2
        w[1][0] = -8
        w[1][2] = 7
        acc_in = [5] + [0 for _ in range(common.TILE_M - 1)]
        scale = [common.ONE_SCALE for _ in range(common.TILE_M)]

        acc_out, y = common.golden_tile(w, x, scale, common.DEFAULT_SHIFT, acc_in, finalize=True)

        self.assertEqual(acc_out[0], 13)
        self.assertEqual(y[0], 13)
        self.assertEqual(acc_out[1], -2)
        self.assertEqual(y[1], -2)
        self.assertTrue(all(value == 0 for value in y[2:]))

    def test_generate_default_case_writes_expected_hex_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)

            summary = w4a8.generate_default_case(out_dir, seed=1)

            expected_files = {
                "tile_16x64_w.hex",
                "tile_16x64_x.hex",
                "tile_16x64_scale.hex",
                "tile_16x64_y_ref.hex",
                "tile_16x64_meta.txt",
            }
            self.assertEqual({path.name for path in out_dir.iterdir()}, expected_files)
            self.assertEqual(summary["w_words"], 128)
            self.assertEqual(summary["x_words"], 16)
            self.assertEqual(summary["scale_words"], 8)
            self.assertEqual(summary["y_words"], 16)

            y_lines = (out_dir / "tile_16x64_y_ref.hex").read_text().splitlines()
            self.assertEqual(len(y_lines), 16)
            self.assertTrue(all(len(line) == 8 for line in y_lines))

    def test_golden_linear_matches_manual_tiled_accumulation(self):
        m = 32
        n = 128
        w = [[0 for _ in range(n)] for _ in range(m)]
        x = [0 for _ in range(n)]
        for col in range(n):
            x[col] = 2 if col % 2 == 0 else -3
        w[0][0] = 7
        w[0][64] = -8
        w[16][1] = -2
        w[16][65] = 4
        scale = [common.ONE_SCALE for _ in range(m)]

        y = common.golden_linear(w, x, scale, common.DEFAULT_SHIFT)

        self.assertEqual(y[0], -2)
        self.assertEqual(y[16], -6)
        self.assertTrue(all(value == 0 for value in y[1:16]))
        self.assertTrue(all(value == 0 for value in y[17:]))

    def test_write_bin_words_uses_little_endian_32_bit_words(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "words.bin"

            common.write_bin_words(path, [0x12345678, -1])

            self.assertEqual(path.read_bytes(), bytes.fromhex("78563412ffffffff"))

    def test_generate_tv_suite_writes_tile_and_linear_bin_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)

            summary = w4a8.generate_tv_suite(out_dir, seed=2)

            expected_cases = {
                "tile_random",
                "tile_boundary",
                "linear_random_32x128",
                "linear_boundary_32x128",
                "linear_awq_like_32x128",
            }
            self.assertEqual(set(summary.keys()), expected_cases)
            for case in expected_cases:
                case_dir = out_dir / case
                self.assertTrue((case_dir / "w.bin").is_file())
                self.assertTrue((case_dir / "x.bin").is_file())
                self.assertTrue((case_dir / "scale.bin").is_file())
                self.assertTrue((case_dir / "y_ref.bin").is_file())
                self.assertTrue((case_dir / "meta.txt").is_file())

            self.assertEqual((out_dir / "tile_random" / "w.bin").stat().st_size, 128 * 4)
            self.assertEqual((out_dir / "tile_random" / "x.bin").stat().st_size, 16 * 4)
            self.assertEqual((out_dir / "tile_random" / "scale.bin").stat().st_size, 8 * 4)
            self.assertEqual((out_dir / "tile_random" / "y_ref.bin").stat().st_size, 16 * 4)

            self.assertEqual((out_dir / "linear_random_32x128" / "w.bin").stat().st_size, 512 * 4)
            self.assertEqual((out_dir / "linear_random_32x128" / "x.bin").stat().st_size, 32 * 4)
            self.assertEqual((out_dir / "linear_random_32x128" / "scale.bin").stat().st_size, 16 * 4)
            self.assertEqual((out_dir / "linear_random_32x128" / "y_ref.bin").stat().st_size, 32 * 4)

    def test_export_c_header_describes_tile_and_linear_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp)
            tv_dir = out_dir / "tv"
            header = out_dir / "test_vectors.h"
            w4a8.generate_tv_suite(tv_dir, seed=3)

            summary = w4a8.export_c_header(tv_dir, header)

            text = header.read_text(encoding="ascii")
            self.assertEqual(summary["cases"], 5)
            self.assertIn("#define W4A8_TV_COUNT 5", text)
            self.assertIn("linear_random_32x128", text)
            self.assertIn("linear_awq_like_32x128", text)
            self.assertIn("static const w4a8_tv_case_t w4a8_tv_cases[W4A8_TV_COUNT]", text)
            self.assertIn(".m = 32", text)
            self.assertIn(".n = 128", text)


if __name__ == "__main__":
    unittest.main()
