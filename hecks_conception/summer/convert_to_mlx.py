#!/usr/bin/env python3
"""Convert a PEFT LoRA adapter to MLX format for local Summer inference.

PEFT saves weights as:
  base_model.model.model.layers.N.self_attn.q_proj.lora_A.weight
  base_model.model.model.layers.N.self_attn.q_proj.lora_B.weight

MLX-LM expects:
  layers.N.self_attn.q_proj.lora_a
  layers.N.self_attn.q_proj.lora_b

This script does the key mapping + transpose (PEFT stores 2D, MLX expects 2D
but transposed for lora_a).

Usage:
  python3 summer/convert_to_mlx.py
  python3 summer/convert_to_mlx.py --source summer/adapter_cloud --dest summer/adapter_v2
"""

import argparse
import json
import os
import sys


def convert(source_dir: str, dest_dir: str):
    """Convert PEFT safetensors to MLX LoRA safetensors."""
    try:
        import numpy as np
        from safetensors.numpy import load_file, save_file
    except ImportError:
        print("❌ Need: pip3 install safetensors numpy")
        sys.exit(1)

    peft_path = os.path.join(source_dir, "adapter_model.safetensors")
    if not os.path.exists(peft_path):
        print(f"❌ No adapter_model.safetensors in {source_dir}")
        sys.exit(1)

    # Load PEFT adapter
    print(f"📥 Loading PEFT adapter from {peft_path}")
    peft_weights = load_file(peft_path)

    # Load metadata
    meta_path = os.path.join(source_dir, "summer_meta.json")
    if os.path.exists(meta_path):
        with open(meta_path) as f:
            meta = json.load(f)
        rank = meta["rank"]
        base_model = meta["base_model"]
    else:
        rank = 16
        base_model = "Qwen/Qwen2.5-3B-Instruct"

    # Map PEFT keys → MLX keys
    mlx_weights = {}
    for peft_key, tensor in peft_weights.items():
        # Strip PEFT prefix
        # base_model.model.model.layers.0.self_attn.q_proj.lora_A.weight
        # → layers.0.self_attn.q_proj.lora_a
        key = peft_key
        key = key.replace("base_model.model.model.", "")
        key = key.replace("base_model.model.", "")
        key = key.replace(".lora_A.weight", ".lora_a")
        key = key.replace(".lora_B.weight", ".lora_b")
        key = key.replace(".lora_A.default.weight", ".lora_a")
        key = key.replace(".lora_B.default.weight", ".lora_b")

        # PEFT lora_A is (rank, in_features) — MLX expects same shape
        # PEFT lora_B is (out_features, rank) — MLX expects same shape
        mlx_weights[key] = tensor.astype(np.float16)
        print(f"  {peft_key[:60]:60s} → {key}")

    # Save MLX adapter
    os.makedirs(dest_dir, exist_ok=True)
    mlx_path = os.path.join(dest_dir, "adapters.safetensors")
    save_file(mlx_weights, mlx_path)
    print(f"\n💾 Saved {len(mlx_weights)} tensors to {mlx_path}")

    # Count layers
    layers = set()
    for k in mlx_weights:
        parts = k.split(".")
        if "layers" in parts:
            idx = parts.index("layers")
            if idx + 1 < len(parts):
                layers.add(int(parts[idx + 1]))

    # Write MLX adapter_config.json
    config = {
        "adapter_path": dest_dir,
        "batch_size": 1,
        "fine_tune_type": "lora",
        "lora_parameters": {
            "rank": rank,
            "dropout": 0.0,
            "scale": rank * 2.0,
        },
        "model": "mlx-community/Qwen2.5-3B-Instruct-4bit",
        "num_layers": len(layers),
    }
    config_path = os.path.join(dest_dir, "adapter_config.json")
    with open(config_path, "w") as f:
        json.dump(config, f, indent=4)
    print(f"📋 Config: {config_path}")

    size_mb = os.path.getsize(mlx_path) / (1024 * 1024)
    print(f"\n☀️  MLX adapter ready: {size_mb:.1f}MB, {len(layers)} layers, rank {rank}")
    print(f"   Test: SUMMER_ADAPTER={dest_dir} python3 summer/serve.py")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Convert PEFT → MLX adapter")
    here = os.path.dirname(os.path.abspath(__file__))
    parser.add_argument("--source", default=os.path.join(here, "adapter_cloud"))
    parser.add_argument("--dest", default=os.path.join(here, "adapter_v2"))
    args = parser.parse_args()
    convert(args.source, args.dest)
