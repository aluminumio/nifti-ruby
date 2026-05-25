# nifti-ruby

Pure-Ruby reader for the NIfTI-1 single-file format (`.nii` and `.nii.gz`), verified bit-identical against Python's [nibabel](https://nipy.org/nibabel/).

## Status

Phase 1: read-only support for NIfTI-1 single-file format. No runtime dependencies.

Out of scope (later phases): writer, NIfTI-2, paired `.hdr`/`.img`, `numo-narray` integration, DICOM helpers.

## Install

```ruby
gem "nifti-ruby"
```

## Usage

```ruby
require "nifti"

volume = Nifti.load("scan.nii.gz")

volume.dim          # => [3, 16, 16, 16, 1, 1, 1, 1]  (the full 8-element dim array)
volume.shape        # => [16, 16, 16]                 (just the spatial dims)
volume.dtype        # => :uint8 | :int16 | :float32 | ...
volume.voxel_size   # => [1.0, 1.0, 1.0]
volume.affine       # => 4x4 Array<Array<Float>>      (sform, qform, or identity fallback)
volume.header       # => Hash of the full decoded 348-byte header
volume.raw_bytes    # => decompressed voxel data as a binary String (native byte order)
volume.to_a         # => Ruby Array of voxel values, properly typed
```

## Verification against nibabel

`spec/golden/` holds nibabel-produced byte-for-byte references. `Nifti#raw_bytes` is asserted to equal the golden voxel-data bytes exactly.

To regenerate the goldens after fixture or pinned-dep changes:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r script/requirements.txt
python3 script/regenerate_golden.py
```

CI does **not** regenerate goldens.

## License

MIT
