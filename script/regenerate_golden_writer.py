#!/usr/bin/env python3
"""
Regenerate golden WRITER artifacts for nifti-ruby.

WHEN TO RUN:
  - You added or changed a writer test case
  - You bumped pinned dep versions in script/requirements.txt

CI does NOT run this script. The goldens it produces are committed.

USAGE:
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -r script/requirements.txt
  python3 script/regenerate_golden_writer.py

Layout per case <name>:
  spec/golden/writer/<name>.input.yaml   # canonical input descriptor
  spec/golden/writer/<name>.nii.gz       # nibabel-saved output (gzipped or raw)
  spec/golden/writer/<name>.nii          # raw variant (when applicable)
  spec/golden/writer/<name>.header.bin   # raw 348-byte header for diffing
  spec/golden/writer/<name>.voxels.bin   # raw decompressed voxel-data bytes

The Ruby writer spec loads each input.yaml, builds the same Numo array, calls
Nifti.write, then byte-compares against <name>.nii(.gz). Where bit-identity
isn't achievable (rare; quaternion last-bit), the spec asserts at the header
field level.
"""

import gzip
from pathlib import Path

import numpy as np
import nibabel as nib
import yaml

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = ROOT / "spec" / "golden" / "writer"
GOLDEN.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# Test cases. Each entry is (name, dtype_str, shape, affine, intent_code,
# intent_name, description, gzipped). The data is generated as
# arange(prod(shape)) % dtype_max cast to dtype, then reshaped Fortran-order
# — same recipe the Ruby spec follows so we don't need to ship the bytes.
# ---------------------------------------------------------------------------
CASES = [
    # Primary case: uint8 16^3 with identity affine -- byte-for-byte target.
    dict(name="uint8_16cubed_identity",
         dtype="uint8",  shape=[16, 16, 16],
         affine=np.eye(4).tolist(),
         intent_code=0,  intent_name="", description="",
         gzipped=True),

    # dtype coverage. All identity affine, small shape, no intent/descrip.
    dict(name="int16_8x8x4",   dtype="int16",   shape=[8, 8, 4],
         affine=np.diag([2.0, 2.0, 3.0, 1.0]).tolist(),
         intent_code=0, intent_name="", description="", gzipped=False),
    dict(name="int32_4x4x4",   dtype="int32",   shape=[4, 4, 4],
         affine=np.eye(4).tolist(),
         intent_code=0, intent_name="", description="", gzipped=True),
    dict(name="float32_4x4x4", dtype="float32", shape=[4, 4, 4],
         affine=np.eye(4).tolist(),
         intent_code=0, intent_name="", description="", gzipped=True),
    dict(name="float64_4x4x4", dtype="float64", shape=[4, 4, 4],
         affine=np.eye(4).tolist(),
         intent_code=0, intent_name="", description="", gzipped=True),

    # Label-map use case (intent + description).
    dict(name="label_map_int32", dtype="int32", shape=[6, 6, 6],
         affine=np.diag([1.5, 1.5, 1.5, 1.0]).tolist(),
         intent_code=1002, intent_name="label_map",
         description="shoulder bone segmentation",
         gzipped=True),
]


def build_data(dtype, shape):
    """Deterministic generator both Python AND Ruby specs use."""
    n = int(np.prod(shape))
    if dtype == "uint8":
        arr = (np.arange(n, dtype=np.int64) % 256).astype(np.uint8)
    elif dtype == "int8":
        arr = ((np.arange(n, dtype=np.int64) % 256) - 128).astype(np.int8)
    elif dtype == "int16":
        arr = (np.arange(n, dtype=np.int64) % 32768).astype(np.int16)
    elif dtype == "uint16":
        arr = (np.arange(n, dtype=np.int64) % 65536).astype(np.uint16)
    elif dtype == "int32":
        # Use a stride so label maps look like labels not 0..N
        arr = ((np.arange(n, dtype=np.int64) * 7) % 1000).astype(np.int32)
    elif dtype == "uint32":
        arr = (np.arange(n, dtype=np.int64) % (1 << 20)).astype(np.uint32)
    elif dtype == "float32":
        arr = (np.arange(n, dtype=np.float32) * 0.5)
    elif dtype == "float64":
        arr = (np.arange(n, dtype=np.float64) * 0.25)
    else:
        raise ValueError(f"unsupported test dtype {dtype}")
    return arr.reshape(shape, order="F")


def write_case(case):
    name = case["name"]
    data = build_data(case["dtype"], case["shape"])
    affine = np.array(case["affine"], dtype=np.float64)

    img = nib.Nifti1Image(data, affine)
    img.header.set_sform(affine, code=2)
    img.header.set_qform(affine, code=2)
    if case["intent_code"]:
        img.header["intent_code"] = case["intent_code"]
    if case["intent_name"]:
        img.header["intent_name"] = case["intent_name"].encode()
    if case["description"]:
        img.header["descrip"] = case["description"].encode()

    ext = ".nii.gz" if case["gzipped"] else ".nii"
    out_path = GOLDEN / f"{name}{ext}"
    nib.save(img, str(out_path))

    # Persist the raw 348-byte header and decompressed voxel bytes so the
    # Ruby spec can diff individual chunks even when full-file diff fails.
    opener = gzip.open if case["gzipped"] else open
    with opener(out_path, "rb") as f:
        all_bytes = f.read()
    (GOLDEN / f"{name}.header.bin").write_bytes(all_bytes[:348])
    (GOLDEN / f"{name}.voxels.bin").write_bytes(all_bytes[352:])

    # Canonical input descriptor consumed by the Ruby spec.
    descriptor = {
        "name": name,
        "dtype": case["dtype"],
        "shape": case["shape"],
        "affine": case["affine"],
        "intent_code": case["intent_code"],
        "intent_name": case["intent_name"],
        "description": case["description"],
        "gzipped": case["gzipped"],
        "output_filename": out_path.name,
    }
    (GOLDEN / f"{name}.input.yaml").write_text(yaml.safe_dump(descriptor, sort_keys=True))
    print(f"  wrote {out_path.name}: shape={case['shape']} dtype={case['dtype']}")


def main():
    print("Regenerating writer goldens:")
    for case in CASES:
        write_case(case)
    print()
    print("Done. Goldens:", sorted(p.name for p in GOLDEN.iterdir()))


if __name__ == "__main__":
    main()
