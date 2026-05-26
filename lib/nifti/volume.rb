# frozen_string_literal: true

module Nifti
  # Immutable in-memory NIfTI-1 volume: parsed header + raw voxel bytes.
  class Volume
    NIFTI1_MAGIC = "n+1"   # single-file format ("n+1\0" on disk)
    NIFTI1_PAIRED = "ni1"  # paired .hdr/.img (Phase 2)
    NIFTI2_MAGIC = "n+2"   # NIfTI-2 single-file (Phase 2)

    attr_reader :header, :raw_bytes, :source

    def initialize(header:, raw_bytes:, source: nil)
      @header = header.freeze
      @raw_bytes = raw_bytes.freeze
      @source = source
    end

    # Parse a full in-memory NIfTI-1 single-file blob (already decompressed).
    def self.from_bytes(bytes, source: nil)
      raise FormatError, "file too small to be a NIfTI-1 header (#{bytes.bytesize} bytes)" if bytes.bytesize < Header::SIZE

      raw_size = bytes.byteslice(0, 4).unpack1("l<")
      byte_order =
        case raw_size
        when 348            then "<"
        when 1_543_569_408  then ">"   # 348 byte-swapped
        when 540            then raise UnsupportedError, "NIfTI-2 files are not supported in Phase 1 (sizeof_hdr=540)"
        else
          raise FormatError, "not a NIfTI-1 file (sizeof_hdr=#{raw_size}, expected 348)"
        end

      header_blob = bytes.byteslice(0, Header::SIZE)
      header = Header.decode(header_blob, byte_order)

      magic = header[:magic]
      case magic
      when NIFTI1_MAGIC
        # ok
      when NIFTI1_PAIRED
        raise UnsupportedError, "paired .hdr/.img NIfTI-1 (magic='ni1') not supported in Phase 1"
      when NIFTI2_MAGIC
        raise UnsupportedError, "NIfTI-2 (magic='n+2') not supported in Phase 1"
      else
        raise FormatError, "not a NIfTI-1 single-file (magic=#{magic.inspect})"
      end

      dtype = Header::DATATYPE[header[:datatype]] or
        raise FormatError, "unknown NIfTI datatype code #{header[:datatype]}"
      bpv = Header::BYTES_PER_VOXEL[dtype] or
        raise UnsupportedError, "datatype #{dtype} not supported in Phase 1"

      shape = extract_shape(header[:dim])
      n_voxels = shape.empty? ? 0 : shape.inject(1, :*)
      expected_bytes = n_voxels * bpv

      vox_offset = header[:vox_offset].to_i
      vox_offset = Header::SIZE + 4 if vox_offset < Header::SIZE + 4 # 352 default

      voxel_bytes = bytes.byteslice(vox_offset, expected_bytes) || "".b
      if voxel_bytes.bytesize != expected_bytes
        raise FormatError,
              "voxel data truncated: expected #{expected_bytes} bytes at offset #{vox_offset}, " \
              "got #{voxel_bytes.bytesize}"
      end

      new(header: header, raw_bytes: voxel_bytes.b, source: source)
    end

    # Full 8-element dim array as stored in the header.
    def dim
      header[:dim]
    end

    # Just the spatial dims (dim[1..dim[0]]).
    def shape
      self.class.extract_shape(header[:dim])
    end

    def dtype
      Header::DATATYPE[header[:datatype]]
    end

    # Voxel size for each spatial dim from pixdim[1..ndim].
    def voxel_size
      header[:pixdim][1, shape.length]
    end

    def byte_order
      header[:byte_order]
    end

    # 4x4 affine: sform takes precedence (sform_code != 0), then qform,
    # else fall back to a voxel-size-scaled identity.
    def affine
      if header[:sform_code] != 0
        [header[:srow_x], header[:srow_y], header[:srow_z], [0.0, 0.0, 0.0, 1.0]]
      elsif header[:qform_code] != 0
        affine_from_qform
      else
        sx, sy, sz = voxel_size + [1.0, 1.0, 1.0]
        [[sx, 0.0, 0.0, 0.0],
         [0.0, sy, 0.0, 0.0],
         [0.0, 0.0, sz, 0.0],
         [0.0, 0.0, 0.0, 1.0]]
      end
    end

    # Voxel values as a Ruby Array, decoded per dtype.
    # Layout matches the on-disk Fortran order (x fastest, then y, then z, ...).
    def to_a
      fmt = unpack_format
      raise UnsupportedError, "to_a not implemented for dtype #{dtype}" unless fmt

      n_voxels = shape.empty? ? 0 : shape.inject(1, :*)
      raw_bytes.unpack("#{fmt}#{n_voxels}")
    end

    def self.extract_shape(dim)
      ndim = dim[0].to_i
      return [] if ndim <= 0
      dim[1, ndim] || []
    end

    # Write this volume to disk as a NIfTI-1 single-file. With no overrides
    # this is a true round-trip: the same data + affine + intent are encoded
    # back. The on-disk bytes may differ from the original file in a few
    # fields where nibabel and Writer use slightly different defaults, but
    # all read-back parsed values match exactly.
    def write(path, **overrides)
      Nifti::Writer.write_raw(
        raw_bytes,
        path,
        shape:       overrides.fetch(:shape, shape),
        dtype:       overrides.fetch(:dtype, dtype),
        affine:      overrides.fetch(:affine, affine),
        voxel_size:  overrides.fetch(:voxel_size, voxel_size),
        description: overrides.fetch(:description, header[:descrip]),
        intent_name: overrides.fetch(:intent_name, header[:intent_name]),
        intent_code: overrides.fetch(:intent_code, header[:intent_code])
      )
    end

    private

    def unpack_format
      le = byte_order == "<"
      case dtype
      when :uint8       then "C"
      when :int8        then "c"
      when :uint16      then le ? "v"  : "n"
      when :int16       then le ? "s<" : "s>"
      when :uint32      then le ? "V"  : "N"
      when :int32       then le ? "l<" : "l>"
      when :uint64      then le ? "Q<" : "Q>"
      when :int64       then le ? "q<" : "q>"
      when :float32     then le ? "e"  : "g"
      when :float64     then le ? "E"  : "G"
      end
    end

    # Convert NIfTI-1 quaternion (quatern_b/c/d + qoffset + pixdim + qfac)
    # into a 4x4 affine matrix. Per the NIfTI-1 spec:
    #   a = sqrt(1 - b^2 - c^2 - d^2)   (or 0 if negative due to rounding)
    #   R = rotation matrix from (a,b,c,d)
    #   pixdim[0] = qfac (+1 or -1); if -1, flip k axis
    def affine_from_qform
      b = header[:quatern_b]
      c = header[:quatern_c]
      d = header[:quatern_d]
      a_sq = 1.0 - (b * b + c * c + d * d)
      a = a_sq < 0 ? 0.0 : Math.sqrt(a_sq)

      r = [
        [a * a + b * b - c * c - d * d, 2 * b * c - 2 * a * d,         2 * b * d + 2 * a * c],
        [2 * b * c + 2 * a * d,         a * a + c * c - b * b - d * d, 2 * c * d - 2 * a * b],
        [2 * b * d - 2 * a * c,         2 * c * d + 2 * a * b,         a * a + d * d - c * c - b * b]
      ]

      qfac = header[:pixdim][0]
      qfac = 1.0 if qfac.zero? || qfac.nan?
      qfac = qfac.negative? ? -1.0 : 1.0

      sx, sy, sz = header[:pixdim][1], header[:pixdim][2], header[:pixdim][3]
      qx, qy, qz = header[:qoffset_x], header[:qoffset_y], header[:qoffset_z]

      [
        [r[0][0] * sx, r[0][1] * sy, r[0][2] * sz * qfac, qx],
        [r[1][0] * sx, r[1][1] * sy, r[1][2] * sz * qfac, qy],
        [r[2][0] * sx, r[2][1] * sy, r[2][2] * sz * qfac, qz],
        [0.0,          0.0,          0.0,                  1.0]
      ]
    end
  end
end
