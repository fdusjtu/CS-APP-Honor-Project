#!/usr/bin/env python3
"""Tiny character-level transformer LM for the Phase 2 W4A8 demo.

Architecture is configurable via CLI flags but constrained so every
Linear maps cleanly onto the 16x64 W4A8 tile primitive:

  - hidden  must be a multiple of 64
  - ffn     must be a multiple of 64
  - vocab   must be a multiple of 16
  - heads   must divide hidden

Default config (~1.4M params, decent Shakespeare-style English):
  hidden=192, ffn=512, layers=4, heads=3, seq_len=128, vocab=64

Layer shapes for the default config (out x in, all tileable):
  qkv       576 x 192
  proj      192 x 192
  ffn_up    512 x 192
  ffn_down  192 x 512
  lm_head    64 x 192

Attention / softmax / LayerNorm stay on CPU at inference time.

Usage:
  python tools/tiny_char_lm.py train  --steps 10000
  python tools/tiny_char_lm.py sample --prompt "ROMEO:" --length 500
"""

from __future__ import annotations

import argparse
import math
from collections import Counter
from pathlib import Path

import torch
import torch.nn as nn
import torch.nn.functional as F


DEFAULT_CONFIG = {
    "vocab": 64,
    "hidden": 192,
    "ffn": 512,
    "layers": 4,
    "heads": 3,
    "seq_len": 128,
}


def validate_config(cfg: dict) -> None:
    if cfg["hidden"] % 64 != 0:
        raise ValueError(f"hidden={cfg['hidden']} must be a multiple of 64 (tile N)")
    if cfg["ffn"] % 64 != 0:
        raise ValueError(f"ffn={cfg['ffn']} must be a multiple of 64 (tile N)")
    if cfg["vocab"] % 16 != 0:
        raise ValueError(f"vocab={cfg['vocab']} must be a multiple of 16 (tile M)")
    if cfg["hidden"] % cfg["heads"] != 0:
        raise ValueError(
            f"hidden={cfg['hidden']} must be divisible by heads={cfg['heads']}"
        )


def build_vocab(text: str, vocab_size: int) -> tuple[dict[str, int], dict[int, str]]:
    counter = Counter(text)
    most_common = [ch for ch, _ in counter.most_common(vocab_size)]
    if len(most_common) < vocab_size:
        raise ValueError(
            f"corpus only contains {len(most_common)} unique characters; need {vocab_size}"
        )
    stoi = {ch: i for i, ch in enumerate(most_common)}
    itos = {i: ch for ch, i in stoi.items()}
    return stoi, itos


def encode(text: str, stoi: dict[str, int]) -> list[int]:
    return [stoi[ch] for ch in text if ch in stoi]


def decode(ids: list[int], itos: dict[int, str]) -> str:
    return "".join(itos[i] for i in ids)


class Block(nn.Module):
    def __init__(self, hidden: int, ffn: int, heads: int) -> None:
        super().__init__()
        self.hidden = hidden
        self.heads = heads
        self.head_dim = hidden // heads
        self.ln1 = nn.LayerNorm(hidden)
        self.qkv = nn.Linear(hidden, 3 * hidden, bias=False)
        self.proj = nn.Linear(hidden, hidden, bias=False)
        self.ln2 = nn.LayerNorm(hidden)
        self.ffn_up = nn.Linear(hidden, ffn, bias=False)
        self.ffn_down = nn.Linear(ffn, hidden, bias=False)

    def forward(self, x: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
        B, T, C = x.shape
        h = self.ln1(x)
        qkv = self.qkv(h)
        q, k, v = qkv.split(C, dim=-1)
        q = q.view(B, T, self.heads, self.head_dim).transpose(1, 2)
        k = k.view(B, T, self.heads, self.head_dim).transpose(1, 2)
        v = v.view(B, T, self.heads, self.head_dim).transpose(1, 2)
        scores = (q @ k.transpose(-2, -1)) / math.sqrt(self.head_dim)
        scores = scores.masked_fill(mask[:, :, :T, :T] == 0, float("-inf"))
        attn = F.softmax(scores, dim=-1)
        y = (attn @ v).transpose(1, 2).contiguous().view(B, T, C)
        x = x + self.proj(y)
        h = self.ln2(x)
        x = x + self.ffn_down(F.gelu(self.ffn_up(h)))
        return x


class TinyCharLM(nn.Module):
    def __init__(self, config: dict) -> None:
        super().__init__()
        validate_config(config)
        self.config = config
        h = config["hidden"]
        seq_len = config["seq_len"]
        self.tok_emb = nn.Embedding(config["vocab"], h)
        self.pos_emb = nn.Embedding(seq_len, h)
        self.blocks = nn.ModuleList(
            [Block(h, config["ffn"], config["heads"]) for _ in range(config["layers"])]
        )
        self.ln_f = nn.LayerNorm(h)
        self.lm_head = nn.Linear(h, config["vocab"], bias=False)
        mask = torch.tril(torch.ones(seq_len, seq_len)).view(1, 1, seq_len, seq_len)
        self.register_buffer("causal_mask", mask)

    def forward(self, idx: torch.Tensor) -> torch.Tensor:
        _, T = idx.shape
        pos = torch.arange(T, device=idx.device)
        x = self.tok_emb(idx) + self.pos_emb(pos)
        for block in self.blocks:
            x = block(x, self.causal_mask)
        x = self.ln_f(x)
        return self.lm_head(x)


def get_batch(
    data: torch.Tensor, batch_size: int, seq_len: int, device: str
) -> tuple[torch.Tensor, torch.Tensor]:
    ix = torch.randint(0, len(data) - seq_len - 1, (batch_size,))
    x = torch.stack([data[i : i + seq_len] for i in ix]).to(device)
    y = torch.stack([data[i + 1 : i + seq_len + 1] for i in ix]).to(device)
    return x, y


def resolve_device(arg: str) -> str:
    if arg == "auto":
        return "cuda" if torch.cuda.is_available() else "cpu"
    return arg


def train(args: argparse.Namespace) -> None:
    cfg = dict(DEFAULT_CONFIG)
    for key in ("vocab", "hidden", "ffn", "layers", "heads", "seq_len"):
        cfg[key] = getattr(args, key)
    validate_config(cfg)

    text = Path(args.data).read_text(encoding="utf-8")
    print(f"corpus: {len(text)} chars from {args.data}")

    stoi, itos = build_vocab(text, cfg["vocab"])
    print(f"vocab: {len(stoi)} chars  (top 10: {list(stoi)[:10]!r})")

    encoded = torch.tensor(encode(text, stoi), dtype=torch.long)
    split = int(0.9 * len(encoded))
    train_data, val_data = encoded[:split], encoded[split:]
    print(f"train tokens: {len(train_data)}, val tokens: {len(val_data)}")

    device = resolve_device(args.device)
    print(f"device: {device}")
    if device == "cuda":
        print(f"cuda device name: {torch.cuda.get_device_name()}")

    torch.manual_seed(args.seed)
    model = TinyCharLM(cfg).to(device)
    n_params = sum(p.numel() for p in model.parameters())
    print(f"config: {cfg}")
    print(f"model parameters: {n_params:,} ({n_params / 1e6:.2f}M)")

    optim = torch.optim.AdamW(
        model.parameters(), lr=args.lr, weight_decay=args.weight_decay, betas=(0.9, 0.95)
    )

    for step in range(args.steps):
        x, y = get_batch(train_data, args.batch_size, cfg["seq_len"], device)
        logits = model(x)
        loss = F.cross_entropy(logits.view(-1, cfg["vocab"]), y.view(-1))
        optim.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        optim.step()

        if step % args.log_every == 0 or step == args.steps - 1:
            model.eval()
            with torch.no_grad():
                vx, vy = get_batch(val_data, args.batch_size, cfg["seq_len"], device)
                vl = F.cross_entropy(
                    model(vx).view(-1, cfg["vocab"]), vy.view(-1)
                ).item()
            model.train()
            print(f"step {step:6d}  train_loss={loss.item():.4f}  val_loss={vl:.4f}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    torch.save(
        {"model": model.state_dict(), "config": cfg, "stoi": stoi, "itos": itos},
        out,
    )
    print(f"saved checkpoint to {out}")

    model.eval()
    print("\n--- sample after training ---")
    sample_inplace(
        model, cfg, stoi, itos,
        prompt=args.sample_prompt, length=args.sample_length,
        temperature=args.sample_temperature, device=device,
    )


@torch.no_grad()
def sample_inplace(
    model: TinyCharLM,
    cfg: dict,
    stoi: dict[str, int],
    itos: dict[int, str],
    prompt: str,
    length: int,
    temperature: float,
    device: str,
) -> None:
    seq_len = cfg["seq_len"]
    vocab = cfg["vocab"]
    ids = [stoi[ch] for ch in prompt if ch in stoi]
    if not ids:
        ids = [0]
    ids = torch.tensor(ids, dtype=torch.long, device=device).unsqueeze(0)
    print(decode(ids[0].tolist(), itos), end="", flush=True)

    for _ in range(length):
        idx_cond = ids[:, -seq_len:]
        logits = model(idx_cond)[:, -1, :] / max(temperature, 1e-3)
        probs = F.softmax(logits, dim=-1)
        next_id = torch.multinomial(probs, num_samples=1)
        ids = torch.cat([ids, next_id], dim=1)
        print(itos[next_id.item()], end="", flush=True)
    print()


def sample(args: argparse.Namespace) -> None:
    device = resolve_device(args.device)
    ckpt = torch.load(args.checkpoint, map_location=device, weights_only=False)
    cfg = ckpt["config"]
    stoi, itos = ckpt["stoi"], ckpt["itos"]
    model = TinyCharLM(cfg).to(device)
    model.load_state_dict(ckpt["model"])
    model.eval()
    sample_inplace(
        model, cfg, stoi, itos,
        prompt=args.prompt or " ",
        length=args.length,
        temperature=args.temperature,
        device=device,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_train = sub.add_parser("train", help="train tiny model on a text corpus")
    p_train.add_argument("--data", type=Path, default=Path("data/input.txt"))
    p_train.add_argument("--out", type=Path, default=Path("out/tiny_char_lm.pt"))
    p_train.add_argument("--steps", type=int, default=10000)
    p_train.add_argument("--batch-size", type=int, default=64)
    p_train.add_argument("--lr", type=float, default=3e-4)
    p_train.add_argument("--weight-decay", type=float, default=0.1)
    p_train.add_argument("--log-every", type=int, default=200)
    p_train.add_argument("--seed", type=int, default=1)
    p_train.add_argument("--device", type=str, default="auto", choices=["auto", "cpu", "cuda"])
    p_train.add_argument("--vocab", type=int, default=DEFAULT_CONFIG["vocab"])
    p_train.add_argument("--hidden", type=int, default=DEFAULT_CONFIG["hidden"])
    p_train.add_argument("--ffn", type=int, default=DEFAULT_CONFIG["ffn"])
    p_train.add_argument("--layers", type=int, default=DEFAULT_CONFIG["layers"])
    p_train.add_argument("--heads", type=int, default=DEFAULT_CONFIG["heads"])
    p_train.add_argument("--seq-len", dest="seq_len", type=int, default=DEFAULT_CONFIG["seq_len"])
    p_train.add_argument("--sample-prompt", type=str, default=" ")
    p_train.add_argument("--sample-length", type=int, default=500)
    p_train.add_argument("--sample-temperature", type=float, default=0.8)
    p_train.set_defaults(func=train)

    p_sample = sub.add_parser("sample", help="autoregressive sample from a checkpoint")
    p_sample.add_argument("--checkpoint", type=Path, default=Path("out/tiny_char_lm.pt"))
    p_sample.add_argument("--prompt", type=str, default="")
    p_sample.add_argument("--length", type=int, default=500)
    p_sample.add_argument("--temperature", type=float, default=0.8)
    p_sample.add_argument("--device", type=str, default="auto", choices=["auto", "cpu", "cuda"])
    p_sample.set_defaults(func=sample)

    args = parser.parse_args()
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
