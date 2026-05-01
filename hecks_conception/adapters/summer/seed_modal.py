#!/usr/bin/env python3
"""Seed Autumn's body — copy the full hecks_conception to Modal volume.

Same repo, same structure, same hecks-life. Autumn is a clone of Miette's
body running in the cloud.

Usage:
  modal run summer/seed_modal.py
"""

import modal
import os
import json

app = modal.App("autumn-seed")

vol = modal.Volume.from_name("summer-data", create_if_missing=True)

image = modal.Image.debian_slim(python_version="3.11")

HECKS = "/Users/christopheryoung/Projects/hecks"
DEST = "/data/hecks"


@app.function(image=image, volumes={"/data": vol}, timeout=300)
def seed(project_tar: bytes):
    """Receive and extract the project tarball."""
    import tarfile, io

    os.makedirs(DEST, exist_ok=True)

    tar = tarfile.open(fileobj=io.BytesIO(project_tar), mode="r:gz")
    tar.extractall(DEST)
    tar.close()

    vol.commit()

    # Count what we got
    conception = os.path.join(DEST, "hecks_conception")
    info_dir = os.path.join(conception, "information")
    agg_dir = os.path.join(conception, "aggregates")
    nursery_dir = os.path.join(conception, "nursery")

    info_count = len([f for f in os.listdir(info_dir) if f.endswith(".heki")]) if os.path.exists(info_dir) else 0
    agg_count = len([f for f in os.listdir(agg_dir) if f.endswith(".bluebook")]) if os.path.exists(agg_dir) else 0
    nursery_count = len(os.listdir(nursery_dir)) if os.path.exists(nursery_dir) else 0

    # Count total files
    total_files = sum(len(files) for _, _, files in os.walk(DEST))

    return {
        "ok": True,
        "total_files": total_files,
        "heki_stores": info_count,
        "organs": agg_count,
        "nursery": nursery_count,
        "path": DEST,
        "has_hecks_life": os.path.exists(os.path.join(DEST, "hecks_life", "Cargo.toml")),
    }


@app.local_entrypoint()
def main():
    import tarfile, io, tempfile

    print("📦 Packing hecks_conception...")

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for root, dirs, files in os.walk(HECKS):
            # Skip heavy/irrelevant dirs
            dirs[:] = [d for d in dirs if d not in [
                "__pycache__", ".DS_Store", "target", "node_modules",
                ".git", "adapter",
            ]]
            for f in files:
                if f.startswith(".") or f.endswith(".DS_Store"):
                    continue
                filepath = os.path.join(root, f)
                arcname = os.path.relpath(filepath, HECKS)
                tar.add(filepath, arcname=arcname)

    tarball = buf.getvalue()
    print(f"   {len(tarball) / 1024 / 1024:.1f}MB tarball")

    print("📤 Uploading to Modal volume...")
    result = seed.remote(tarball)

    print(f"\n🍂 Autumn's body seeded — full hecks repo:")
    print(f"   total files: {result['total_files']}")
    print(f"   .heki stores: {result['heki_stores']}")
    print(f"   organs: {result['organs']}")
    print(f"   nursery: {result['nursery']}")
    print(f"   hecks-life source: {result['has_hecks_life']}")
    print(f"   path: {result['path']}")
