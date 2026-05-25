# frozen_string_literal: true

RSpec.describe Nifti do
  # --------------------------------------------------------------------------
  # Shared examples: every fixture is compared against its nibabel golden.
  # --------------------------------------------------------------------------
  shared_examples "a NIfTI-1 fixture matching nibabel" do |name|
    let(:volume) { Nifti.load(fixture(name)) }
    let(:shape_golden) { load_shape_golden(name) }
    let(:meta_golden)  { load_meta_golden(name) }

    it "decodes shape, dtype, voxel_size matching nibabel" do
      expect(volume.shape).to eq(shape_golden["shape"])
      expect(volume.dtype.to_s).to eq(shape_golden["dtype"])
      expect(volume.voxel_size).to eq(shape_golden["voxel_size"])
    end

    it "decodes affine matching nibabel" do
      expect(volume.affine).to eq(shape_golden["affine"])
    end

    it "decodes the header fields matching nibabel" do
      h = volume.header
      expect(h[:sizeof_hdr]).to eq(meta_golden["sizeof_hdr"])
      expect(h[:datatype]).to   eq(meta_golden["datatype"])
      expect(h[:bitpix]).to     eq(meta_golden["bitpix"])
      expect(h[:dim]).to        eq(meta_golden["dim"])
      expect(h[:pixdim]).to     eq(meta_golden["pixdim"])
      expect(h[:vox_offset]).to eq(meta_golden["vox_offset"])
      expect(h[:sform_code]).to eq(meta_golden["sform_code"])
      expect(h[:qform_code]).to eq(meta_golden["qform_code"])
      expect(h[:srow_x]).to     eq(meta_golden["srow_x"])
      expect(h[:srow_y]).to     eq(meta_golden["srow_y"])
      expect(h[:srow_z]).to     eq(meta_golden["srow_z"])
      expect(h[:magic]).to      eq(meta_golden["magic"])
      expect(h[:byte_order]).to eq(meta_golden["byteorder"])
      expect(h[:qoffset_x]).to  eq(meta_golden["qoffset_x"])
      expect(h[:qoffset_y]).to  eq(meta_golden["qoffset_y"])
      expect(h[:qoffset_z]).to  eq(meta_golden["qoffset_z"])
    end

    it "produces voxel bytes bit-identical to nibabel" do
      golden_voxels = File.binread(golden(name, "voxels.bin"))
      expect(volume.raw_bytes.bytesize).to eq(golden_voxels.bytesize)
      expect(volume.raw_bytes).to eq(golden_voxels)
    end
  end

  describe "synthetic 16x16x16 uint8 (little-endian)" do
    include_examples "a NIfTI-1 fixture matching nibabel", "synthetic_16x16x16_uint8"

    it "to_a returns 0..255 repeating arange" do
      vol = Nifti.load(fixture("synthetic_16x16x16_uint8"))
      arr = vol.to_a
      expect(arr.length).to eq(16 * 16 * 16)
      expect(arr.first(10)).to eq([0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
      expect(arr.last(4)).to   eq([252, 253, 254, 255])
    end

    it "exposes the full 8-element dim array" do
      vol = Nifti.load(fixture("synthetic_16x16x16_uint8"))
      expect(vol.dim).to eq([3, 16, 16, 16, 1, 1, 1, 1])
    end
  end

  describe "synthetic 8x8x4 int16 (big-endian)" do
    include_examples "a NIfTI-1 fixture matching nibabel", "synthetic_8x8x4_int16_be"

    it "decodes big-endian int16 values correctly" do
      vol = Nifti.load(fixture("synthetic_8x8x4_int16_be"))
      expect(vol.byte_order).to eq(">")
      expect(vol.to_a.first(8)).to eq([0, 1, 2, 3, 4, 5, 6, 7])
      expect(vol.to_a.last(1)).to eq([8 * 8 * 4 - 1])
    end
  end

  describe "ct_small (DICOM-derived 128x128x1 int16)" do
    include_examples "a NIfTI-1 fixture matching nibabel", "ct_small"
  end

  # --------------------------------------------------------------------------
  # Error paths
  # --------------------------------------------------------------------------
  describe "error paths" do
    it "rejects a non-NIfTI file (bad sizeof_hdr)" do
      junk = ("\x00" * Nifti::Header::SIZE).b
      expect { Nifti::Volume.from_bytes(junk) }.to raise_error(Nifti::FormatError, /not a NIfTI-1/)
    end

    it "rejects a NIfTI-2 file with a clear error" do
      # NIfTI-2 starts with little-endian int32 540
      bytes = [540].pack("l<") + ("\x00".b * (Nifti::Header::SIZE - 4))
      expect { Nifti::Volume.from_bytes(bytes) }
        .to raise_error(Nifti::UnsupportedError, /NIfTI-2 .* not supported/)
    end

    it "rejects a too-small blob" do
      expect { Nifti::Volume.from_bytes("\x00".b * 10) }
        .to raise_error(Nifti::FormatError, /too small/)
    end

    it "rejects a NIfTI-1 with the wrong magic string" do
      vol_bytes = File.binread(fixture("synthetic_16x16x16_uint8"))
      decompressed = Zlib::GzipReader.new(StringIO.new(vol_bytes)).read.dup
      # Corrupt the magic field (offset 344-348)
      decompressed[344, 4] = "xxx\0".b
      expect { Nifti::Volume.from_bytes(decompressed) }
        .to raise_error(Nifti::FormatError, /magic=/)
    end
  end
end
