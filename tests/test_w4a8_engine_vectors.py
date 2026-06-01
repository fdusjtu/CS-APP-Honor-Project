import random
import tempfile
import unittest
from pathlib import Path

from tools import w4a8_common as common
from tools import w4a8_engine_vectors as eng


class LayerTableTests(unittest.TestCase):
    def test_target_table_has_nine_layers_in_engine_order(self):
        layers = eng.build_layer_table(eng.TARGET_CONFIG)
        names = [ly["name"] for ly in layers]
        self.assertEqual(
            names,
            [
                "layer0_qkv", "layer0_proj", "layer0_ffn_up", "layer0_ffn_down",
                "layer1_qkv", "layer1_proj", "layer1_ffn_up", "layer1_ffn_down",
                "lm_head",
            ],
        )
        self.assertEqual([ly["id"] for ly in layers], list(range(9)))

    def test_target_shapes(self):
        by_name = {ly["name"]: (ly["M"], ly["N"]) for ly in eng.build_layer_table(eng.TARGET_CONFIG)}
        self.assertEqual(by_name["layer0_qkv"], (384, 128))
        self.assertEqual(by_name["layer0_ffn_up"], (256, 128))
        self.assertEqual(by_name["layer0_ffn_down"], (128, 256))
        self.assertEqual(by_name["lm_head"], (64, 128))


class BaseAssignmentTests(unittest.TestCase):
    def test_cumulative_bases_match_frozen_spec(self):
        layers = eng.build_layer_table(eng.TARGET_CONFIG)
        total_w, total_s = eng.assign_bases(layers)
        w_base = {ly["name"]: ly["w_base"] for ly in layers}
        s_base = {ly["name"]: ly["s_base"] for ly in layers}
        self.assertEqual(
            [w_base[n] for n in (
                "layer0_qkv", "layer0_proj", "layer0_ffn_up", "layer0_ffn_down",
                "layer1_qkv", "layer1_proj", "layer1_ffn_up", "layer1_ffn_down",
                "lm_head")],
            [0, 384, 512, 768, 1024, 1408, 1536, 1792, 2048],
        )
        self.assertEqual(
            [s_base[n] for n in (
                "layer0_qkv", "layer0_proj", "layer0_ffn_up", "layer0_ffn_down",
                "layer1_qkv", "layer1_proj", "layer1_ffn_up", "layer1_ffn_down",
                "lm_head")],
            [0, 192, 256, 384, 448, 640, 704, 832, 896],
        )
        self.assertEqual(total_w, 2112)
        self.assertEqual(total_s, 928)
        self.assertLessEqual(total_w, eng.WMEM_BANK_DEPTH)

    def test_rejects_bad_row_multiple(self):
        with self.assertRaises(ValueError):
            eng.assign_bases([{"name": "bad", "M": 24, "N": 64}])

    def test_rejects_bad_col_multiple(self):
        with self.assertRaises(ValueError):
            eng.assign_bases([{"name": "bad", "M": 16, "N": 32}])

    def test_rejects_overflow(self):
        # one huge layer past 4096 bank_addr slots
        with self.assertRaises(ValueError):
            eng.assign_bases([{"name": "huge", "M": 16 * 4097, "N": 64}])


class BankLayoutTests(unittest.TestCase):
    def test_bank_pack_length(self):
        rng = random.Random(0)
        M, N = 32, 64
        W_q = [[rng.randint(-8, 7) for _ in range(N)] for _ in range(M)]
        words = eng.bank_pack_layer(W_q)
        self.assertEqual(len(words), M * N // 8)

    def test_engine_read_round_trips_every_element(self):
        rng = random.Random(7)
        M, N = 32, 128  # 2 row tiles, 16 col words
        W_q = [[rng.randint(-8, 7) for _ in range(N)] for _ in range(M)]
        flat = eng.bank_pack_layer(W_q)  # w_base = 0 for a standalone layer
        for r in range(M):
            for c in range(N):
                self.assertEqual(
                    eng.engine_read_nibble(flat, 0, N, r, c),
                    W_q[r][c],
                    msg=f"mismatch at ({r},{c})",
                )

    def test_engine_read_respects_w_base_offset(self):
        rng = random.Random(9)
        M, N = 16, 64
        W_q = [[rng.randint(-8, 7) for _ in range(N)] for _ in range(M)]
        # prepend a dummy layer's worth of words; engine reads from w_base.
        w_base = 5
        flat = [0] * (w_base * eng.N_BANKS) + eng.bank_pack_layer(W_q)
        for r in range(M):
            for c in range(0, N, 7):
                self.assertEqual(eng.engine_read_nibble(flat, w_base, N, r, c), W_q[r][c])

    def test_scale_word_layout(self):
        scale_q = [100, -200, 300, -400, 500, 600]  # 6 rows -> 3 words
        words = eng.scale_pack_layer(scale_q)
        self.assertEqual(len(words), 3)
        for r in range(6):
            half = (words[r // 2] >> (16 * (r % 2))) & 0xFFFF
            self.assertEqual(common._sign_extend(half, 16), scale_q[r])


class EndToEndTests(unittest.TestCase):
    def test_self_test_passes_for_target_config(self):
        eng.self_test(eng.TARGET_CONFIG)  # raises on failure

    def test_golden_matches_golden_linear(self):
        vec = eng.build_vectors(eng.TARGET_CONFIG, seed=3, weights=None)
        for c in vec["cases"]:
            expect = common.golden_linear(c["W_q"], c["x"], c["scale_q"], common.DEFAULT_SHIFT)
            self.assertEqual(c["y"], expect, msg=c["name"])
            self.assertEqual(len(c["y"]), c["M"])

    def test_streams_align_with_descriptors(self):
        vec = eng.build_vectors(eng.TARGET_CONFIG, seed=1, weights=None)
        # each layer's flat weight offset == w_base * 16
        for c in vec["cases"]:
            start = c["w_base"] * eng.N_BANKS
            sub = vec["w_load_stream"][start:start + c["M"] * c["N"] // 8]
            self.assertEqual(eng.engine_read_nibble(sub, 0, c["N"], 0, 0), c["W_q"][0][0])

    def test_export_firmware_selftest_header_writes_compact_layer_arrays(self):
        with tempfile.TemporaryDirectory() as tmp:
            vec = eng.build_vectors(eng.TARGET_CONFIG, seed=1, weights=None)
            header = Path(tmp) / "w4a8_selftest_vectors.h"

            summary = eng.export_firmware_selftest_header(vec, header, case_id=1)

            text = header.read_text(encoding="ascii")
            self.assertEqual(summary["layer_name"], "layer0_proj")
            self.assertEqual(summary["w_words"], 2048)
            self.assertEqual(summary["s_words"], 64)
            self.assertEqual(summary["act_words"], 32)
            self.assertEqual(summary["y_words"], 128)
            self.assertIn("#define W4A8_ST_M 128", text)
            self.assertIn("#define W4A8_ST_N 128", text)
            self.assertIn("static const uint32_t w4a8_st_w_load[W4A8_ST_W_WORDS]", text)
            self.assertIn("static const uint32_t w4a8_st_s_load[W4A8_ST_S_WORDS]", text)
            self.assertIn("static const uint32_t w4a8_st_act[W4A8_ST_ACT_WORDS]", text)
            self.assertIn("static const int32_t w4a8_st_y_ref[W4A8_ST_Y_WORDS]", text)

    def test_bram_init_export_splits_flat_weight_stream_by_bank(self):
        with tempfile.TemporaryDirectory() as tmp:
            vec = eng.build_vectors(eng.TARGET_CONFIG, seed=1, weights=None)
            out_dir = Path(tmp)

            summary = eng.export_bram_init_files(vec, out_dir)

            self.assertEqual(summary["w_bank_depth"], eng.WMEM_BANK_DEPTH)
            self.assertEqual(summary["s_depth"], eng.SMEM_DEPTH)
            for bank in range(eng.N_BANKS):
                words = [
                    int(line, 16)
                    for line in (out_dir / f"wmem_bank{bank:02d}.hex").read_text().splitlines()
                ]
                self.assertEqual(len(words), eng.WMEM_BANK_DEPTH)
                for addr in (0, 1, vec["total_bank_slots"] - 1):
                    self.assertEqual(words[addr], vec["w_load_stream"][addr * eng.N_BANKS + bank])

            smem_words = [int(line, 16) for line in (out_dir / "smem.hex").read_text().splitlines()]
            self.assertEqual(len(smem_words), eng.SMEM_DEPTH)
            self.assertEqual(smem_words[:len(vec["s_load_stream"])], vec["s_load_stream"])

    def test_export_full_firmware_selftest_header_omits_resident_weights(self):
        with tempfile.TemporaryDirectory() as tmp:
            vec = eng.build_vectors(eng.TARGET_CONFIG, seed=1, weights=None)
            header = Path(tmp) / "w4a8_selftest_vectors.h"

            summary = eng.export_full_firmware_selftest_header(vec, header)

            text = header.read_text(encoding="ascii")
            self.assertEqual(summary["layers"], 9)
            self.assertEqual(summary["act_words"], 352)
            self.assertEqual(summary["y_words"], 1856)
            self.assertIn("#define W4A8_ST_N_LAYERS 9", text)
            self.assertIn("w4a8_st_layers[W4A8_ST_N_LAYERS]", text)
            self.assertIn("w4a8_st_act[W4A8_ST_ACT_WORDS]", text)
            self.assertIn("w4a8_st_y_ref[W4A8_ST_Y_WORDS]", text)
            self.assertNotIn("w4a8_st_w_load", text)
            self.assertNotIn("w4a8_st_s_load", text)


if __name__ == "__main__":
    unittest.main()
