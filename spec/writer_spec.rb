# frozen_string_literal: true

require "numo/narray"
require "tmpdir"

RSpec.describe Nifti::Writer do
  WRITER_GOLDEN = File.join(SpecPaths::ROOT, "spec", "golden", "writer")

  # Mirrors script/regenerate_golden_writer.py:build_data
  def self.build_numo(dtype, shape)
    n = shape.inject(1, :*)
    seq = Numo::Int64.new(n).seq # 0..n-1 in a wide int so modulus doesn't overflow

    flat, klass =
      case dtype
      when "uint8"   then [Numo::UInt8.cast(seq % 256),                 Numo::UInt8]
      when "int8"    then [Numo::Int8.cast((seq % 256) - 128),          Numo::Int8]
      when "int16"   then [Numo::Int16.cast(seq % 32768),               Numo::Int16]
      when "uint16"  then [Numo::UInt16.cast(seq % 65536),              Numo::UInt16]
      when "int32"   then [Numo::Int32.cast((seq * 7) % 1000),          Numo::Int32]
      when "uint32"  then [Numo::UInt32.cast(seq % (1 << 20)),          Numo::UInt32]
      when "float32" then [Numo::SFloat.cast(seq) * 0.5,                Numo::SFloat]
      when "float64" then [Numo::DFloat.cast(seq) * 0.25,               Numo::DFloat]
      else raise "unsupported dtype #{dtype}"
      end

    # Numpy reshape(order='F') produces an array where the first axis varies
    # fastest. To mimic this with a C-order Numo array, reshape into the
    # reversed shape and transpose all axes back.
    klass.cast(flat).reshape(*shape.reverse).transpose(*(0...shape.length).to_a.reverse).dup
  end

  def self.golden_path(name, ext)
    File.join(WRITER_GOLDEN, "#{name}.#{ext}")
  end

  def self.load_input(name)
    YAML.safe_load_file(golden_path(name, "input.yaml"))
  end

  # --------------------------------------------------------------------------
  # Per-case shared examples: byte-for-byte (or, where impossible, field-wise)
  # comparison of Ruby's output against nibabel's golden.
  # --------------------------------------------------------------------------
  shared_examples "a writer case matching nibabel" do |case_name|
    let(:input)    { self.class.load_input(case_name) }
    let(:data)     { self.class.build_numo(input["dtype"], input["shape"]) }
    let(:affine)   { input["affine"] }
    let(:out_path) { File.join(@tmpdir, input["output_filename"]) }

    around(:each) do |ex|
      Dir.mktmpdir("nifti-writer-spec") do |dir|
        @tmpdir = dir
        ex.run
      end
    end

    it "writes a payload that reads back to the same data, affine, dtype, shape" do
      Nifti.write(data, out_path,
                  affine:      affine,
                  intent_code: input["intent_code"],
                  intent_name: input["intent_name"],
                  description: input["description"])

      vol = Nifti.load(out_path)
      expect(vol.shape).to eq(input["shape"])
      expect(vol.dtype.to_s).to eq(input["dtype"])
      expect(vol.affine).to eq(affine)
      expect(vol.header[:intent_code]).to eq(input["intent_code"])
      expect(vol.header[:intent_name]).to eq(input["intent_name"])
      expect(vol.header[:descrip]).to eq(input["description"])

      # And the voxel bytes match the nibabel golden voxels.bin exactly.
      golden_voxels = File.binread(self.class.golden_path(case_name, "voxels.bin"))
      expect(vol.raw_bytes.bytesize).to eq(golden_voxels.bytesize)
      expect(vol.raw_bytes).to eq(golden_voxels)
    end

    it "produces a header byte-for-byte identical to nibabel" do
      Nifti.write(data, out_path,
                  affine:      affine,
                  intent_code: input["intent_code"],
                  intent_name: input["intent_name"],
                  description: input["description"])

      ours_full = read_payload(out_path, input["gzipped"])
      ours_header  = ours_full.byteslice(0, 348)
      golden_header = File.binread(self.class.golden_path(case_name, "header.bin"))

      # If they diverge, surface the offsets that differ so it's easy to triage
      # (e.g. quatern_b/c/d last-bit ULP, scl_slope encoding).
      if ours_header != golden_header
        diffs = (0...348).select { |i| ours_header.getbyte(i) != golden_header.getbyte(i) }
        fail "header bytes differ at offsets #{diffs.first(40).inspect}" \
             " (#{diffs.length} total); ours[280..295]=" \
             "#{ours_header.byteslice(280, 16).bytes.inspect}, " \
             "theirs[280..295]=#{golden_header.byteslice(280, 16).bytes.inspect}"
      end
      expect(ours_header).to eq(golden_header)
    end

    it "produces a decompressed payload (header + ext-marker + voxels) " \
       "byte-for-byte identical to nibabel" do
      Nifti.write(data, out_path,
                  affine:      affine,
                  intent_code: input["intent_code"],
                  intent_name: input["intent_name"],
                  description: input["description"])

      ours    = read_payload(out_path, input["gzipped"])
      ext     = input["gzipped"] ? "nii.gz" : "nii"
      theirs  = read_payload(self.class.golden_path(case_name, ext), input["gzipped"])
      expect(ours.bytesize).to eq(theirs.bytesize)
      expect(ours).to eq(theirs)
    end
  end

  # Helper: read the bytes from a written file, transparently decompressing.
  def read_payload(path, gzipped)
    raw = File.binread(path)
    return raw unless gzipped

    Zlib::GzipReader.new(StringIO.new(raw)).read.force_encoding(Encoding::BINARY)
  end

  describe "uint8 16^3 identity affine (primary byte-for-byte target)" do
    include_examples "a writer case matching nibabel", "uint8_16cubed_identity"
  end

  describe "int16 8x8x4 diag affine, raw .nii" do
    include_examples "a writer case matching nibabel", "int16_8x8x4"
  end

  describe "int32 4^3 identity" do
    include_examples "a writer case matching nibabel", "int32_4x4x4"
  end

  describe "float32 4^3 identity" do
    include_examples "a writer case matching nibabel", "float32_4x4x4"
  end

  describe "float64 4^3 identity" do
    include_examples "a writer case matching nibabel", "float64_4x4x4"
  end

  describe "label_map int32 with intent_code 1002" do
    include_examples "a writer case matching nibabel", "label_map_int32"
  end

  # --------------------------------------------------------------------------
  # Round-trip identity: read existing fixture, write back unchanged, read again.
  # The cheapest correctness signal that the writer doesn't lose anything.
  # --------------------------------------------------------------------------
  describe "round-trip identity via Volume#write" do
    %w[ct_small synthetic_16x16x16_uint8].each do |fixture_name|
      it "preserves data + affine + key header fields for #{fixture_name}" do
        original = Nifti.load(fixture(fixture_name))

        Dir.mktmpdir do |dir|
          out_path = File.join(dir, "#{fixture_name}.nii.gz")
          original.write(out_path)
          reloaded = Nifti.load(out_path)

          expect(reloaded.shape).to     eq(original.shape)
          expect(reloaded.dtype).to     eq(original.dtype)
          expect(reloaded.affine).to    eq(original.affine)
          expect(reloaded.voxel_size).to eq(original.voxel_size)
          expect(reloaded.raw_bytes).to eq(original.raw_bytes)
          expect(reloaded.header[:datatype]).to eq(original.header[:datatype])
          expect(reloaded.header[:bitpix]).to   eq(original.header[:bitpix])
          expect(reloaded.header[:dim]).to      eq(original.header[:dim])
          expect(reloaded.header[:magic]).to    eq(original.header[:magic])
        end
      end
    end
  end

  # --------------------------------------------------------------------------
  # Gzip vs raw: same data should round-trip identically through both.
  # --------------------------------------------------------------------------
  describe "gzip vs raw .nii output" do
    it "produces identical voxel bytes + affine when written to both" do
      data = self.class.build_numo("uint8", [8, 8, 8])
      affine = [[1.0, 0.0, 0.0, 0.0],
                [0.0, 1.0, 0.0, 0.0],
                [0.0, 0.0, 1.0, 0.0],
                [0.0, 0.0, 0.0, 1.0]]

      Dir.mktmpdir do |dir|
        raw_path = File.join(dir, "v.nii")
        gz_path  = File.join(dir, "v.nii.gz")
        Nifti.write(data, raw_path, affine: affine)
        Nifti.write(data, gz_path,  affine: affine)

        raw_vol = Nifti.load(raw_path)
        gz_vol  = Nifti.load(gz_path)
        expect(raw_vol.raw_bytes).to eq(gz_vol.raw_bytes)
        expect(raw_vol.affine).to eq(gz_vol.affine)
        expect(raw_vol.header.except(:byte_order)).to eq(gz_vol.header.except(:byte_order))

        # And the on-disk decompressed gz file is byte-identical to the raw file.
        expect(Nifti.read_all(gz_path)).to eq(File.binread(raw_path))
      end
    end
  end

  # --------------------------------------------------------------------------
  # Spot checks
  # --------------------------------------------------------------------------
  describe "convenience" do
    it "raises when given a plain Array without dtype/shape" do
      Dir.mktmpdir do |dir|
        expect do
          Nifti.write([1, 2, 3], File.join(dir, "x.nii"), affine: Array.new(4) { Array.new(4, 0.0) })
        end.to raise_error(ArgumentError, /dtype:/)
      end
    end

    it "auto-derives voxel_size from a diagonal affine" do
      data = self.class.build_numo("uint8", [4, 4, 4])
      affine = [[2.5, 0.0, 0.0, 0.0],
                [0.0, 1.5, 0.0, 0.0],
                [0.0, 0.0, 3.0, 0.0],
                [0.0, 0.0, 0.0, 1.0]]
      Dir.mktmpdir do |dir|
        path = File.join(dir, "v.nii.gz")
        Nifti.write(data, path, affine: affine)
        expect(Nifti.load(path).voxel_size).to eq([2.5, 1.5, 3.0])
      end
    end
  end
end
