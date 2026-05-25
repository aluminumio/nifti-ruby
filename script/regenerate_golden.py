#!/usr/bin/env python3
"""
Regenerate spec fixtures and golden artifacts for nifti-ruby.

WHEN TO RUN:
  - You changed the fixtures (added/removed/modified)
  - You bumped pinned dependency versions in script/requirements.txt

CI does NOT run this script. The goldens it produces are committed.

USAGE:
  python3 -m venv .venv
  source .venv/bin/activate
  pip install -r script/requirements.txt
  python3 script/regenerate_golden.py

What it produces, per fixture <name>.nii.gz in spec/fixtures/:
  spec/golden/<name>.header.bin   raw 348-byte NIfTI-1 header bytes
  spec/golden/<name>.voxels.bin   raw decompressed voxel-data bytes
  spec/golden/<name>.meta.yaml    full decoded header as a YAML dict
  spec/golden/<name>.shape.yaml   [shape, dtype_name, voxel_size, affine_2d_list]

It also generates the two committed fixtures themselves from scratch so the
repo is reproducible without external inputs at regeneration time (the DICOM
source is read from dicom-imager only for the one-off CT_small conversion).
"""

import gzip
import os
import sys
from pathlib import Path

import numpy as np
import nibabel as nib
import yaml

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "spec" / "fixtures"
GOLDEN = ROOT / "spec" / "golden"
DICOM_SOURCE = Path(
    "/Users/jonathan/Projects/dicom-imager/spec/fixtures/files/CT_small.dcm"
)

FIX.mkdir(parents=True, exist_ok=True)
GOLDEN.mkdir(parents=True, exist_ok=True)


def to_py(value):
    """Convert numpy scalars / arrays into plain Python types for YAML."""
    if isinstance(value, np.ndarray):
        if value.ndim == 0:
            return to_py(value.item())
        return [to_py(v) for v in value.tolist()]
    if isinstance(value, (np.generic,)):
        return value.item()
    if isinstance(value, (bytes, bytearray)):
        try:
            return value.decode("utf-8").rstrip("\x00")
        except UnicodeDecodeError:
            return value.hex()
    if isinstance(value, list):
        return [to_py(v) for v in value]
    return value


def header_to_dict(hdr):
    out = {}
    for key in hdr.keys():
        out[key] = to_py(hdr[key])
    return out


def write_goldens(name, nii_path):
    img = nib.load(str(nii_path))
    hdr = img.header

    # 1) raw 348-byte header bytes (from disk; nibabel may rewrite, so go to disk)
    with (gzip.open(nii_path, "rb") if str(nii_path).endswith(".gz") else open(nii_path, "rb")) as f:
        header_bytes = f.read(348)
    (GOLDEN / f"{name}.header.bin").write_bytes(header_bytes)

    # 2) raw voxel-data bytes (decompressed), as stored on disk.
    # For NIfTI-1 single-file (magic 'n+1\0'), data must start at offset >= 352
    # (16-aligned). nibabel writes 0.0 in the field, which means "default".
    with (gzip.open(nii_path, "rb") if str(nii_path).endswith(".gz") else open(nii_path, "rb")) as f:
        all_bytes = f.read()
    vox_offset = int(hdr["vox_offset"])
    if vox_offset < 352:
        vox_offset = 352
    voxel_bytes = all_bytes[vox_offset:]
    # Trim to exact expected size
    dtype = img.get_data_dtype()
    n_voxels = int(np.prod(img.shape))
    expected = n_voxels * dtype.itemsize
    voxel_bytes = voxel_bytes[:expected]
    (GOLDEN / f"{name}.voxels.bin").write_bytes(voxel_bytes)

    # 3) full decoded header as YAML.
    # We re-parse the on-disk header bytes rather than trusting
    # nibabel's in-memory normalization (e.g. nibabel zeros out vox_offset
    # when it equals the implicit default of 352 for the single-file format).
    fresh = nib.Nifti1Header.from_fileobj(__import__("io").BytesIO(header_bytes))
    meta = header_to_dict(fresh)
    meta["sform_code"] = int(fresh["sform_code"])
    meta["qform_code"] = int(fresh["qform_code"])
    meta["byteorder"] = "<" if fresh.endianness == "<" else ">"
    (GOLDEN / f"{name}.meta.yaml").write_text(yaml.safe_dump(meta, sort_keys=True))

    # 4) high-level shape/dtype/voxel_size/affine summary
    affine = img.affine.tolist()
    voxel_size = [float(z) for z in hdr.get_zooms()[: img.ndim]]
    shape_summary = {
        "shape": list(img.shape),
        "dtype": str(dtype.name),
        "voxel_size": voxel_size,
        "affine": affine,
        "sform_code": int(hdr["sform_code"]),
        "qform_code": int(hdr["qform_code"]),
    }
    (GOLDEN / f"{name}.shape.yaml").write_text(yaml.safe_dump(shape_summary, sort_keys=True))

    print(f"  wrote goldens for {name}: shape={img.shape} dtype={dtype.name} "
          f"voxel_bytes={len(voxel_bytes)}")


# ---------------------------------------------------------------------------
# Fixture 1: synthetic 16x16x16 uint8, identity affine, voxel size [1,1,1]
# ---------------------------------------------------------------------------
def build_synthetic():
    name = "synthetic_16x16x16_uint8"
    data = (np.arange(16 * 16 * 16, dtype=np.int64) % 256).astype(np.uint8).reshape(
        (16, 16, 16), order="F"
    )
    # Use Fortran order so the on-disk byte stream is arange(0..4095) mod 256.
    affine = np.eye(4, dtype=np.float64)
    img = nib.Nifti1Image(data, affine)
    img.header.set_zooms((1.0, 1.0, 1.0))
    img.header.set_sform(affine, code=2)  # 2 = aligned
    img.header.set_qform(affine, code=2)
    out = FIX / f"{name}.nii.gz"
    nib.save(img, str(out))
    print(f"built {out}")
    return name, out


# ---------------------------------------------------------------------------
# Fixture 2: big-endian variant of the synthetic volume
# ---------------------------------------------------------------------------
def build_synthetic_bigendian():
    """Hand-build a big-endian NIfTI-1 single-file so we can verify the Ruby
    reader handles non-native byte order. nibabel's Nifti1Image always saves
    in native byte order, so we do the encoding ourselves."""
    name = "synthetic_8x8x4_int16_be"
    shape = (8, 8, 4)
    data = np.arange(np.prod(shape), dtype=">i2").reshape(shape, order="F")
    affine = np.diag([2.0, 2.0, 3.0, 1.0]).astype(np.float64)

    # Build a header in big-endian, then serialize.
    hdr = nib.Nifti1Header(endianness=">")
    hdr.set_data_dtype(">i2")
    hdr.set_data_shape(shape)
    hdr.set_zooms((2.0, 2.0, 3.0))
    hdr.set_sform(affine, code=2)
    hdr.set_qform(affine, code=2)
    hdr["vox_offset"] = 352
    hdr["magic"] = b"n+1\0"
    header_bytes = hdr.binaryblock  # 348 bytes, big-endian
    assert len(header_bytes) == 348

    # 4-byte extension marker (all zero = no extensions), then voxel data in F-order BE.
    voxel_bytes = data.tobytes(order="F")
    assert len(voxel_bytes) == np.prod(shape) * 2

    out = FIX / f"{name}.nii.gz"
    with gzip.open(out, "wb") as f:
        f.write(header_bytes)
        f.write(b"\x00\x00\x00\x00")  # extension marker
        f.write(voxel_bytes)
    print(f"built {out} (big-endian, hand-rolled)")
    return name, out


# ---------------------------------------------------------------------------
# Fixture 3: CT_small.dcm -> NIfTI (single-slice 128x128 int16)
# ---------------------------------------------------------------------------
def build_ct_small():
    name = "ct_small"
    if not DICOM_SOURCE.exists():
        print(f"!! skipping ct_small: source DICOM not found at {DICOM_SOURCE}",
              file=sys.stderr)
        return None
    import pydicom
    ds = pydicom.dcmread(str(DICOM_SOURCE))
    pixels = ds.pixel_array  # (rows, cols) for single slice
    if pixels.ndim == 2:
        # Promote to 3D so NIfTI treats it as a single-slice volume
        pixels = pixels[:, :, np.newaxis]
    # Ensure int16
    pixels = pixels.astype(np.int16)

    # Build an affine from PixelSpacing + SliceThickness if available, else identity
    try:
        ps = [float(x) for x in ds.PixelSpacing]  # [row_spacing, col_spacing]
    except Exception:
        ps = [1.0, 1.0]
    try:
        st = float(ds.SliceThickness)
    except Exception:
        st = 1.0
    affine = np.diag([ps[1], ps[0], st, 1.0]).astype(np.float64)

    img = nib.Nifti1Image(pixels, affine)
    img.header.set_zooms((ps[1], ps[0], st))
    img.header.set_sform(affine, code=2)
    img.header.set_qform(affine, code=2)
    out = FIX / f"{name}.nii.gz"
    nib.save(img, str(out))
    print(f"built {out}")
    return name, out


def main():
    fixtures = []
    fixtures.append(build_synthetic())
    fixtures.append(build_synthetic_bigendian())
    ct = build_ct_small()
    if ct:
        fixtures.append(ct)

    print()
    print("Writing goldens:")
    for name, path in fixtures:
        write_goldens(name, path)

    print()
    print("Done. Fixtures:", sorted(p.name for p in FIX.iterdir()))
    print("Goldens:      ", sorted(p.name for p in GOLDEN.iterdir()))


if __name__ == "__main__":
    main()
