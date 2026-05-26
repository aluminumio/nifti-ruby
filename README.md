# nifti-ruby

Pure-Ruby reader **and writer** for the NIfTI-1 single-file format (`.nii` and `.nii.gz`), verified bit-identical against Python's [nibabel](https://nipy.org/nibabel/).

## Status

- Phase 1: read-only support for NIfTI-1 single-file format. No runtime dependencies.
- Phase 2: writer (this release). Optional `numo-narray` integration for typed-array input.

Out of scope (later phases): NIfTI-2, paired `.hdr`/`.img`, DICOM helpers.

## Install

```ruby
gem "nifti-ruby"
```

## Read

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

## Write

```ruby
require "nifti"
require "numo/narray"

# Full round-trip (read, optionally modify, write)
volume = Nifti.load("input.nii.gz")
volume.write("output.nii.gz")  # bit-equivalent re-encode

# Or build from scratch:
data   = Numo::Int32.new(64, 64, 32).fill(0)   # label map
affine = [[1.5, 0, 0, 0], [0, 1.5, 0, 0], [0, 0, 1.5, 0], [0, 0, 0, 1]]

Nifti.write(data, "labels.nii.gz",
            affine:      affine,
            description: "shoulder bone segmentation",
            intent_name: "label_map",
            intent_code: 1002)
```

Supported dtypes (inferred from `Numo::NArray` class, or via `dtype:` kwarg
for plain Arrays): `:uint8`, `:int8`, `:uint16`, `:int16`, `:uint32`, `:int32`,
`:uint64`, `:int64`, `:float32`, `:float64`. `Numo::Bit` is auto-cast to UInt8
so boolean masks Just Work.

`.nii.gz` paths are gzip-compressed automatically; `.nii` paths are raw.

## Verification against nibabel

`spec/golden/` holds nibabel-produced byte-for-byte references for the reader.
`spec/golden/writer/` holds the reverse goldens for the writer — given the
same input, Ruby's output and nibabel's output are header-byte-identical (and
decompressed-payload-identical) across all tested dtypes and the label-map
intent case.

To regenerate the goldens after fixture or pinned-dep changes:

```sh
python3 -m venv .venv
source .venv/bin/activate
pip install -r script/requirements.txt
python3 script/regenerate_golden.py            # reader fixtures
python3 script/regenerate_golden_writer.py     # writer goldens
```

CI does **not** regenerate goldens.

## License

MIT
