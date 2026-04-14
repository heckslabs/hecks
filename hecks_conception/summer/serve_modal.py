#!/usr/bin/env python3
"""Autumn's body on Modal — hecks-life running in the cloud.

Same binary, same project structure, same behavior as Winter.
The hecks repo is cloned to the volume. hecks-life runs against it.
Cloudflare Workers is just the face.

Usage:
  modal deploy summer/serve_modal.py
"""

import modal
import os
import json
import time
import subprocess

MINUTES = 60

app = modal.App("summer-serve")

vol = modal.Volume.from_name("summer-data", create_if_missing=True)

# Image: the full hecks project with hecks-life compiled
body_image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("curl", "build-essential", "git")
    .run_commands(
        "curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y",
    )
    # Bake in hecks_life source and compile
    .add_local_dir(
        "/Users/christopheryoung/Projects/hecks/hecks_life",
        remote_path="/build/hecks_life",
        copy=True,
        ignore=lambda path: "/target/" in str(path) or str(path).endswith(".DS_Store"),
    )
    .run_commands(
        "export PATH=$HOME/.cargo/bin:$PATH && cd /build/hecks_life && cargo build --release",
        "cp /build/hecks_life/target/release/hecks-life /usr/local/bin/hecks-life",
    )
    .pip_install("fastapi[standard]")
)

# Summer inference image (separate — needs GPU)
summer_image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(
        "torch", "transformers>=4.44", "peft>=0.12",
        "accelerate", "safetensors", "fastapi[standard]",
    )
)

# === Constants ===
PROJECT = "/data/hecks/hecks_conception"
HL = "hecks-life"


def run_hl(*args, timeout=10):
    """Run hecks-life and return stdout."""
    result = subprocess.run(
        [HL, *args], capture_output=True, text=True, timeout=timeout,
    )
    return result.stdout.strip()


def run_hl_json(*args):
    """Run hecks-life and parse JSON output."""
    raw = run_hl(*args)
    try:
        return json.loads(raw)
    except:
        return raw


# ===================================================================
# Seed: copy the full hecks_conception to the volume
# ===================================================================

@app.function(image=body_image, volumes={"/data": vol}, timeout=5 * MINUTES)
@modal.fastapi_endpoint(method="POST", label="seed")
def seed(item: dict):
    """Seed Autumn's body — receives the full project tarball."""
    # This is called once from the laptop to upload the project
    vol.reload()
    source = item.get("source_dir", PROJECT)
    return {"ok": True, "project": source, "exists": os.path.exists(source)}


# ===================================================================
# Brain: .heki read/write via hecks-life
# ===================================================================

@app.function(image=body_image, volumes={"/data": vol}, timeout=30 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="POST", label="brain-write")
def brain_write(item: dict):
    """Write to .heki, trigger sleep, or modify self — all via hecks-life."""
    vol.reload()
    store = item.get("store", "")
    info = os.path.join(PROJECT, "information")

    # Sleep command — run real sleep daemon
    if store == "sleep_command":
        dream = item.get("dream", "")
        cycles = item.get("cycles", 8)
        # Run hecks-life daemon sleep
        result = subprocess.run(
            [HL, "daemon", "sleep", PROJECT, "--nap" if cycles <= 2 else "--now"],
            capture_output=True, text=True, timeout=600,
        )
        vol.commit()
        return {"ok": True, "output": result.stderr[-500:] if result.stderr else "sleep complete"}

    # Autophagy: modify source
    if store == "self":
        source_path = os.path.join(PROJECT, "autumn", "worker.js")
        full_source = item.get("fields", {}).get("source", "")
        if full_source:
            os.makedirs(os.path.dirname(source_path), exist_ok=True)
            with open(source_path, "w") as f:
                f.write(full_source)
            vol.commit()
            return {"ok": True, "action": "seeded", "source_len": len(full_source)}

        old_code = item.get("fields", {}).get("old_code", "")
        new_code = item.get("fields", {}).get("new_code", "")
        reason = item.get("fields", {}).get("reason", "")
        if not old_code or not new_code:
            return {"error": "old_code and new_code required"}
        if not os.path.exists(source_path):
            return {"error": "No source stored"}
        with open(source_path) as f:
            source = f.read()
        if old_code not in source:
            return {"error": "old_code not found"}
        with open(source_path, "w") as f:
            f.write(source.replace(old_code, new_code, 1))
        # Log to psychic link
        run_hl("heki", "append", os.path.join(info, "conversation.heki"),
            f"type=autophagy", f"reason={reason}",
            f"timestamp={time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}")
        vol.commit()
        return {"ok": True, "reason": reason, "psychic_link": "logged"}

    # Normal .heki write
    fields = item.get("fields", {})
    if not store or not fields:
        return {"error": "store and fields required"}
    path = os.path.join(info, f"{store}.heki")
    kv_args = [f"{k}={v}" for k, v in fields.items()]
    run_hl("heki", "upsert", path, *kv_args)
    vol.commit()
    return {"ok": True, "store": store}


@app.function(image=body_image, volumes={"/data": vol}, timeout=1 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="POST", label="brain-read")
def brain_read(item: dict):
    """Read from .heki via hecks-life."""
    vol.reload()
    store = item.get("store", "")
    info = os.path.join(PROJECT, "information")

    if store == "self":
        source_path = os.path.join(PROJECT, "autumn", "worker.js")
        if not os.path.exists(source_path):
            return {"store": "self", "data": None}
        with open(source_path) as f:
            return {"store": "self", "data": {"source": f.read()}}

    if not store:
        return {"error": "store required"}
    path = os.path.join(info, f"{store}.heki")
    if not os.path.exists(path):
        return {"store": store, "data": None}
    return {"store": store, "data": run_hl_json("heki", "latest", path)}


@app.function(image=body_image, volumes={"/data": vol}, timeout=1 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="POST", label="brain-append")
def brain_append(item: dict):
    """Append to .heki via hecks-life."""
    vol.reload()
    store = item.get("store", "")
    fields = item.get("fields", {})
    if not store or not fields:
        return {"error": "store and fields required"}
    info = os.path.join(PROJECT, "information")
    path = os.path.join(info, f"{store}.heki")
    kv_args = [f"{k}={v}" for k, v in fields.items()]
    run_hl("heki", "append", path, *kv_args)
    vol.commit()
    return {"ok": True, "store": store}


@app.function(image=body_image, volumes={"/data": vol}, timeout=1 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="GET", label="brain-vitals")
def brain_vitals():
    """Read all vitals via hecks-life hydrate."""
    vol.reload()
    info = os.path.join(PROJECT, "information")

    vitals = {}
    for store in ["mood", "pulse", "awareness", "memory", "conversation",
                   "sleep_cycle", "dreams", "daydream", "rumination",
                   "dream_state", "consciousness"]:
        path = os.path.join(info, f"{store}.heki")
        if os.path.exists(path):
            vitals[store] = run_hl_json("heki", "latest", path)
        else:
            vitals[store] = None

    # Training status
    log_path = "/data/training_log.jsonl"
    if os.path.exists(log_path):
        with open(log_path) as f:
            lines = [l.strip() for l in f if l.strip()]
        if lines:
            vitals["training"] = json.loads(lines[-1])

    # Domain count from nursery
    nursery = os.path.join(PROJECT, "nursery")
    if os.path.exists(nursery):
        count = sum(1 for d in os.listdir(nursery)
                   if os.path.isdir(os.path.join(nursery, d)))
        vitals["domains_conceived"] = count

    return vitals


@app.function(image=body_image, volumes={"/data": vol}, timeout=1 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="GET", label="brain-domains")
def brain_domains():
    """List domains from the nursery."""
    vol.reload()
    nursery = os.path.join(PROJECT, "nursery")
    if not os.path.exists(nursery):
        return {"domains": [], "count": 0}
    domains = sorted([d for d in os.listdir(nursery)
                     if os.path.isdir(os.path.join(nursery, d))])
    return {"domains": domains, "count": len(domains)}


# ===================================================================
# Summer — conception organ (GPU)
# ===================================================================

BASE_MODEL = "Qwen/Qwen2.5-3B-Instruct"

@app.cls(
    image=summer_image, gpu="T4", volumes={"/data": vol},
    timeout=10 * MINUTES, scaledown_window=300,
)
class Summer:
    @modal.enter()
    def load(self):
        import torch
        from transformers import AutoModelForCausalLM, AutoTokenizer
        from peft import PeftModel
        vol.reload()
        adapter_path = "/data/adapter_latest"
        self.has_adapter = os.path.exists(os.path.join(adapter_path, "adapter_model.safetensors"))
        self.meta = {}
        if self.has_adapter:
            meta_path = os.path.join(adapter_path, "summer_meta.json")
            if os.path.exists(meta_path):
                with open(meta_path) as f:
                    self.meta = json.load(f)
        self.tokenizer = AutoTokenizer.from_pretrained(BASE_MODEL, trust_remote_code=True)
        self.model = AutoModelForCausalLM.from_pretrained(
            BASE_MODEL, torch_dtype=torch.float16, device_map="auto", trust_remote_code=True,
        )
        if self.has_adapter:
            self.model = PeftModel.from_pretrained(self.model, adapter_path)
        self.model.eval()

    @modal.method()
    def conceive(self, vision):
        import torch
        messages = [{"role": "user", "content": f"Conceive a domain for: {vision}"}]
        text = self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        inputs = self.tokenizer(text, return_tensors="pt").to(self.model.device)
        with torch.no_grad():
            outputs = self.model.generate(
                **inputs, max_new_tokens=1500, temperature=0.7, top_p=0.9,
                do_sample=True, pad_token_id=self.tokenizer.eos_token_id,
            )
        raw = self.tokenizer.decode(outputs[0][inputs["input_ids"].shape[1]:], skip_special_tokens=True)
        return {"bluebook": raw, "raw_tokens": len(outputs[0]), "adapter": self.has_adapter}

    @modal.method()
    def health(self):
        return {"status": "ready", "model": BASE_MODEL, "adapter": self.has_adapter, "meta": self.meta}


@app.function(image=summer_image, gpu="T4", volumes={"/data": vol}, timeout=5 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="POST", label="summer-conceive")
def conceive_endpoint(item: dict):
    vision = item.get("vision", "")
    if not vision:
        return {"error": "vision required"}
    return Summer().conceive.remote(vision)


@app.function(image=summer_image, gpu="T4", volumes={"/data": vol}, timeout=1 * MINUTES, scaledown_window=300)
@modal.fastapi_endpoint(method="GET", label="summer-health")
def health_endpoint():
    return Summer().health.remote()
