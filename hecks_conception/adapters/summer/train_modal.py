#!/usr/bin/env python3
"""Summer training on Modal — LoRA fine-tune on Miette's domains.

Seeds with 405 real bluebook pairs extracted from Miette's conception,
then trains Summer (Qwen2.5-3B) with LoRA on a cloud GPU.

Usage:
  modal run summer/train_modal.py                    # train
  modal run summer/train_modal.py --iters 1000       # more iterations
  modal run summer/train_modal.py --download          # pull adapter
"""

import modal
import os
import json
import time

MINUTES = 60
HOURS = 60 * MINUTES

app = modal.App("summer-training")

vol = modal.Volume.from_name("summer-data", create_if_missing=True)

training_image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "torch",
        "transformers>=4.44",
        "peft>=0.12",
        "datasets",
        "accelerate",
        "bitsandbytes",
        "safetensors",
        "trl>=0.9",
    )
)


@app.function(
    image=training_image,
    gpu="A100",
    timeout=2 * HOURS,
    volumes={"/data": vol},
)
def train(
    train_jsonl: str,
    valid_jsonl: str,
    raw_train: str,
    raw_valid: str,
    base_model: str = "Qwen/Qwen2.5-3B-Instruct",
    iters: int = 600,
    rank: int = 16,
    learning_rate: float = 2e-5,
):
    """LoRA fine-tune Summer on Miette's domains."""
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from peft import LoraConfig, get_peft_model
    from trl import SFTTrainer, SFTConfig
    from datasets import Dataset

    # Save training data to volume for Summer serving to reference
    os.makedirs("/data/training", exist_ok=True)
    os.makedirs("/data/domains", exist_ok=True)

    with open("/data/training/train.jsonl", "w") as f:
        f.write(train_jsonl)
    with open("/data/training/valid.jsonl", "w") as f:
        f.write(valid_jsonl)
    with open("/data/training/train_raw.jsonl", "w") as f:
        f.write(raw_train)
    with open("/data/training/valid_raw.jsonl", "w") as f:
        f.write(raw_valid)

    # Count pairs
    train_data = [json.loads(l) for l in train_jsonl.strip().split("\n") if l.strip()]
    valid_data = [json.loads(l) for l in valid_jsonl.strip().split("\n") if l.strip()]

    print(f"🌱 Summer training on Miette's domains")
    print(f"   {len(train_data)} train / {len(valid_data)} valid")
    print(f"   rank={rank}, iters={iters}, lr={learning_rate}")
    print(f"   base: {base_model}")

    train_ds = Dataset.from_list(train_data)
    valid_ds = Dataset.from_list(valid_data)

    # Load model
    print(f"  📥 Loading {base_model}...")
    tokenizer = AutoTokenizer.from_pretrained(base_model, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    model = AutoModelForCausalLM.from_pretrained(
        base_model, torch_dtype=torch.bfloat16, device_map="auto", trust_remote_code=True,
        attn_implementation="eager",
    )
    model.gradient_checkpointing_enable()

    # LoRA
    lora_config = LoraConfig(
        r=rank, lora_alpha=rank * 2, lora_dropout=0.05,
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
        bias="none", task_type="CAUSAL_LM",
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    # Train
    training_args = SFTConfig(
        output_dir="/data/checkpoints",
        max_steps=iters,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=8,
        learning_rate=learning_rate,
        lr_scheduler_type="cosine",
        warmup_steps=min(50, iters // 10),
        logging_steps=25,
        save_steps=200,
        eval_strategy="steps",
        eval_steps=200,
        bf16=True,
        max_length=2048,
        gradient_checkpointing=True,
        report_to="none",
        seed=42,
    )

    trainer = SFTTrainer(
        model=model, args=training_args,
        train_dataset=train_ds, eval_dataset=valid_ds,
        processing_class=tokenizer,
    )

    print("  🚀 Training...")
    result = trainer.train()

    # Save adapter
    adapter_path = "/data/adapter_latest"
    trainer.save_model(adapter_path)
    tokenizer.save_pretrained(adapter_path)

    meta = {
        "round": 1,
        "base_model": base_model,
        "rank": rank,
        "learning_rate": learning_rate,
        "iters": iters,
        "train_pairs": len(train_data),
        "valid_pairs": len(valid_data),
        "final_loss": result.training_loss,
        "source": "miette_domains",
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
    }
    with open(os.path.join(adapter_path, "summer_meta.json"), "w") as f:
        json.dump(meta, f, indent=2)

    # Training log
    with open("/data/training_log.jsonl", "a") as f:
        f.write(json.dumps(meta) + "\n")

    vol.commit()
    print(f"  ✅ Done! Loss: {result.training_loss:.4f}")
    print(f"  📦 Adapter saved to volume — Summer serving will pick it up")
    return meta


@app.function(
    image=modal.Image.debian_slim(python_version="3.11"),
    volumes={"/data": vol},
)
def get_adapter() -> dict:
    """Download the trained adapter."""
    vol.reload()
    adapter_path = "/data/adapter_latest"
    if not os.path.exists(adapter_path):
        return {"error": "No adapter found"}
    files = {}
    for fname in os.listdir(adapter_path):
        fpath = os.path.join(adapter_path, fname)
        if os.path.isfile(fpath):
            with open(fpath, "rb") as f:
                files[fname] = f.read()
    return files


@app.local_entrypoint()
def main(
    iters: int = 600,
    rank: int = 16,
    learning_rate: float = 2e-5,
    download: bool = False,
):
    if download:
        print("📥 Downloading adapter...")
        files = get_adapter.remote()
        if "error" in files:
            print(f"❌ {files['error']}")
            return
        local_dir = os.path.expanduser("~/Projects/hecks/hecks_conception/summer/adapter_cloud")
        os.makedirs(local_dir, exist_ok=True)
        for fname, data in files.items():
            if isinstance(data, str): data = data.encode()
            with open(os.path.join(local_dir, fname), "wb") as f:
                f.write(data)
            print(f"  💾 {fname}: {len(data):,} bytes")
        print(f"\n☀️  Adapter at {local_dir}")
        print(f"   Convert: python3 summer/convert_to_mlx.py")
        return

    # Read local training data
    print("📤 Reading Miette's domains...")
    train_chat = open("/tmp/summer_seed/train.jsonl").read()
    valid_chat = open("/tmp/summer_seed/valid.jsonl").read()
    raw_train = open("/tmp/summer_seed/train_raw.jsonl").read()
    raw_valid = open("/tmp/summer_seed/valid_raw.jsonl").read()

    t = len([l for l in train_chat.strip().split("\n") if l.strip()])
    v = len([l for l in valid_chat.strip().split("\n") if l.strip()])
    print(f"   {t} train / {v} valid pairs from 413 bluebooks")

    print(f"\n☀️  Training Summer — rank={rank}, iters={iters}")
    print(f"   This runs on Modal A10G. ~15-20 min.\n")

    meta = train.remote(
        train_jsonl=train_chat,
        valid_jsonl=valid_chat,
        raw_train=raw_train,
        raw_valid=raw_valid,
        iters=iters,
        rank=rank,
        learning_rate=learning_rate,
    )

    print(f"\n✅ Training complete!")
    print(f"   Loss: {meta['final_loss']:.4f}")
    print(f"   Pairs: {meta['train_pairs']} train / {meta['valid_pairs']} valid")
    print(f"   Summer serving will auto-load the new adapter on next request.")
