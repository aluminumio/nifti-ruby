# frozen_string_literal: true

module Nifti
  # NIfTI-1 single-file (.nii / .nii.gz) writer. Mirrors the on-disk layout
  # described in Header. Produces output byte-compatible with nibabel's
  # `Nifti1Image(data, affine)` save path (modulo the qform quaternion's last
  # bit, where Ruby's Math.sqrt and Python's numpy can diverge; see comments
  # in `qform_from_affine`).
  #
  # Always writes little-endian (matches nibabel's native-byte-order default on
  # x86/arm + matches what the reader expects in the common case).
  module Writer
    module_function

    # Datatype mapping for inputs we accept. Per entry: NIfTI :code, :bitpix,
    # and the little-endian Array#pack format used to encode flat Ruby values.
    DTYPES = {
      uint8:   { code: 2,  bitpix: 8,  pack: "C*"  },
      int8:    { code: 256, bitpix: 8, pack: "c*"  },
      int16:   { code: 4,  bitpix: 16, pack: "s<*" },
      uint16:  { code: 512, bitpix: 16, pack: "v*" },
      int32:   { code: 8,  bitpix: 32, pack: "l<*" },
      uint32:  { code: 768, bitpix: 32, pack: "V*" },
      int64:   { code: 1024, bitpix: 64, pack: "q<*" },
      uint64:  { code: 1280, bitpix: 64, pack: "Q<*" },
      float32: { code: 16, bitpix: 32, pack: "e*"  },
      float64: { code: 64, bitpix: 64, pack: "E*"  }
    }.freeze

    # 16-byte padded header offset: 348 → 352 (next 16-byte boundary).
    VOX_OFFSET = 352.0

    # Encode + write a volume to disk. Auto-gzips when path ends in `.nii.gz`.
    #
    # data    : array-like; either a Numo::NArray (preferred — dtype is inferred)
    #           or a plain Ruby Array (in which case `dtype:` must be given).
    # path    : destination filename (`.nii` or `.nii.gz`).
    # affine  : 4x4 matrix (4-element array of 4-element arrays, or a Numo
    #           array). Populates srow_x/y/z and qform fields.
    # voxel_size  : optional [sx, sy, sz]; derived from affine if omitted.
    # description : optional 80-char free-text descrip field.
    # intent_name : optional 16-char intent_name field.
    # intent_code : optional NIfTI intent code (uint16).
    # dtype       : optional dtype symbol; required for plain-Array data.
    # shape       : optional shape override; required for plain-Array data.
    def write(data, path,
              affine:,
              voxel_size: nil,
              description: nil,
              intent_name: nil,
              intent_code: 0,
              dtype: nil,
              shape: nil)
      shape, dtype, voxel_bytes = encode_data(data, dtype: dtype, shape: shape)

      raise UnsupportedError, "unsupported dtype #{dtype.inspect}" unless DTYPES.key?(dtype)

      voxel_size ||= derive_voxel_size(affine, shape.length)
      header_bytes = build_header(
        shape:       shape,
        dtype:       dtype,
        affine:      affine,
        voxel_size:  voxel_size,
        description: description,
        intent_name: intent_name,
        intent_code: intent_code
      )

      # 4-byte extension marker (no extensions) + voxel data. Total header
      # block on disk is 352 bytes (= VOX_OFFSET).
      payload = header_bytes + "\x00\x00\x00\x00".b + voxel_bytes

      write_bytes(path, payload)
      path
    end

    # Like `write`, but `voxel_bytes` is the already-encoded on-disk Fortran-
    # order byte string (e.g. from Volume#raw_bytes). Used for true round-trip
    # via Volume#write — bypasses the Numo/Ruby reordering step.
    def write_raw(voxel_bytes, path,
                  shape:,
                  dtype:,
                  affine:,
                  voxel_size:   nil,
                  description:  nil,
                  intent_name:  nil,
                  intent_code:  0)
      raise UnsupportedError, "unsupported dtype #{dtype.inspect}" unless DTYPES.key?(dtype)

      voxel_size ||= derive_voxel_size(affine, shape.length)
      header_bytes = build_header(
        shape:       shape,
        dtype:       dtype,
        affine:      affine,
        voxel_size:  voxel_size,
        description: description,
        intent_name: intent_name,
        intent_code: intent_code
      )
      payload = header_bytes + "\x00\x00\x00\x00".b + voxel_bytes.b
      write_bytes(path, payload)
      path
    end

    # -------------------------------------------------------------------------
    # Internals
    # -------------------------------------------------------------------------

    # Returns [shape, dtype_symbol, voxel_bytes_little_endian].
    # Voxels are emitted in Fortran (column-major) order, matching nibabel's
    # default on-disk layout for Nifti1Image(data, affine).
    def encode_data(data, dtype: nil, shape: nil)
      if defined?(Numo::NArray) && data.is_a?(Numo::NArray)
        encode_numo(data)
      else
        raise ArgumentError, "dtype: required when data is not a Numo::NArray" unless dtype
        raise ArgumentError, "shape: required when data is not a Numo::NArray" unless shape

        flat = data.respond_to?(:flatten) ? data.flatten : data.to_a
        bytes = pack_flat(flat, dtype)
        [shape, dtype, bytes]
      end
    end

    # Map a Numo::NArray to (shape, dtype, packed-bytes-in-fortran-order).
    def encode_numo(arr)
      shape = arr.shape
      sym = numo_dtype_symbol(arr)
      # Numo stores in C-order; transpose reverses axes so a subsequent
      # row-major flatten matches Fortran order on the original axes.
      reordered = arr.transpose(*((arr.ndim - 1).downto(0).to_a))
      flat = reordered.flatten.to_a
      [shape, sym, pack_flat(flat, sym)]
    end

    def numo_dtype_symbol(arr)
      case arr
      when Numo::UInt8   then :uint8
      when Numo::Int8    then :int8
      when Numo::UInt16  then :uint16
      when Numo::Int16   then :int16
      when Numo::UInt32  then :uint32
      when Numo::Int32   then :int32
      when Numo::UInt64  then :uint64
      when Numo::Int64   then :int64
      when Numo::SFloat  then :float32
      when Numo::DFloat  then :float64
      when Numo::Bit     then :uint8 # mask/label-map convention
      else
        raise UnsupportedError, "unsupported Numo dtype #{arr.class}"
      end
    end

    def pack_flat(values, dtype)
      meta = DTYPES.fetch(dtype) { raise UnsupportedError, "unsupported dtype #{dtype.inspect}" }
      values.pack(meta[:pack])
    end

    def build_header(shape:, dtype:, affine:, voxel_size:, description:, intent_name:, intent_code:)
      meta = DTYPES.fetch(dtype)
      ndim = shape.length

      # dim[0]=ndim; spatial dims fill dim[1..ndim]; remaining dim slots = 1.
      dim = Array.new(8, 1)
      dim[0] = ndim
      shape.each_with_index { |n, i| dim[i + 1] = n.to_i }

      # pixdim[0] = qfac (we always pick +1 below). pixdim[1..ndim] = voxel size.
      pixdim = Array.new(8, 1.0)
      pixdim[0] = 1.0
      voxel_size.each_with_index { |s, i| pixdim[i + 1] = s.to_f }

      qb, qc, qd, qx, qy, qz = qform_from_affine(affine)

      affine_rows = affine_to_rows(affine)

      blob = String.new(capacity: Header::SIZE, encoding: Encoding::BINARY)
      blob << [Header::SIZE].pack("l<")               # 0..3   sizeof_hdr
      blob << "\x00".b * 10                            # 4..13  data_type
      blob << "\x00".b * 18                            # 14..31 db_name
      blob << [0].pack("l<")                           # 32..35 extents
      blob << [0].pack("s<")                           # 36..37 session_error
      blob << "\x00".b                                 # 38     regular
      blob << "\x00".b                                 # 39     dim_info
      blob << dim.pack("s<8")                          # 40..55 dim[8]
      blob << [0.0, 0.0, 0.0].pack("e3")               # 56..67 intent_p1/p2/p3
      blob << [intent_code.to_i].pack("s<")            # 68..69 intent_code
      blob << [meta[:code]].pack("s<")                 # 70..71 datatype
      blob << [meta[:bitpix]].pack("s<")               # 72..73 bitpix
      blob << [0].pack("s<")                           # 74..75 slice_start
      blob << pixdim.pack("e8")                        # 76..107 pixdim[8]
      blob << [VOX_OFFSET].pack("e")                   # 108..111 vox_offset
      # scl_slope=1.0, scl_inter=0.0 matches what nibabel actually writes
      # for `Nifti1Image(data, affine)` (the spec's "NaN" hint is wrong for
      # the on-disk default — verified against the existing reader goldens).
      blob << [1.0].pack("e")                          # 112..115 scl_slope
      blob << [0.0].pack("e")                          # 116..119 scl_inter
      blob << [0].pack("s<")                           # 120..121 slice_end
      blob << "\x00".b                                 # 122 slice_code
      blob << "\x00".b                                 # 123 xyzt_units
      blob << [0.0, 0.0].pack("e2")                    # 124..131 cal_max/min
      blob << [0.0, 0.0].pack("e2")                    # 132..139 slice_duration/toffset
      blob << [0, 0].pack("l<2")                       # 140..147 glmax/glmin
      blob << fixed_string(description, 80)            # 148..227 descrip
      blob << fixed_string(nil, 24)                    # 228..251 aux_file
      blob << [2].pack("s<")                           # 252..253 qform_code = ALIGNED_ANAT
      blob << [2].pack("s<")                           # 254..255 sform_code = ALIGNED_ANAT
      blob << [qb, qc, qd].pack("e3")                  # 256..267 quatern_b/c/d
      blob << [qx, qy, qz].pack("e3")                  # 268..279 qoffset_x/y/z
      blob << affine_rows[0].pack("e4")                # 280..295 srow_x
      blob << affine_rows[1].pack("e4")                # 296..311 srow_y
      blob << affine_rows[2].pack("e4")                # 312..327 srow_z
      blob << fixed_string(intent_name, 16)            # 328..343 intent_name
      blob << "n+1\x00".b                              # 344..347 magic
      raise "header size mismatch #{blob.bytesize}" unless blob.bytesize == Header::SIZE

      blob.force_encoding(Encoding::BINARY)
    end

    def fixed_string(str, size)
      s = (str || "").to_s.b
      s = s.byteslice(0, size) if s.bytesize > size
      s + ("\x00".b * (size - s.bytesize))
    end

    # Pull the first three rows of the 4x4 affine as plain Float arrays.
    def affine_to_rows(affine)
      rows = if defined?(Numo::NArray) && affine.is_a?(Numo::NArray)
               affine.to_a
             else
               affine.map { |r| r.respond_to?(:to_a) ? r.to_a : r }
             end
      rows[0, 3].map { |row| row.map(&:to_f) }
    end

    # Derive [sx, sy, sz] from the spatial columns of the affine.
    def derive_voxel_size(affine, ndim)
      rows = affine_to_rows(affine)
      # Column norms of the rotation/scale block.
      sizes = (0...ndim).map do |c|
        Math.sqrt(rows.sum { |row| row[c].to_f**2 })
      end
      sizes
    end

    # Compute the NIfTI-1 quaternion (b,c,d) + offsets (qx,qy,qz) from a 4x4
    # affine. This is the Shoemake factorization that nibabel uses; for an
    # orthogonal affine (the only kind we promise to round-trip exactly) the
    # outputs are bit-identical to nibabel modulo last-bit float ULPs.
    #
    # For an identity rotation this returns (0,0,0) — i.e. the quaternion (1,0,0,0).
    def qform_from_affine(affine)
      rows = affine_to_rows(affine)
      # Translation = 4th column.
      qx = rows[0][3].to_f
      qy = rows[1][3].to_f
      qz = rows[2][3].to_f

      # Extract 3x3 rotation/scale, normalize columns to unit length to get R.
      r = (0..2).map { |i| (0..2).map { |j| rows[i][j].to_f } }
      col_norm = (0..2).map { |j| Math.sqrt((0..2).sum { |i| r[i][j]**2 }) }
      rn = (0..2).map { |i| (0..2).map { |j| col_norm[j].zero? ? 0.0 : r[i][j] / col_norm[j] } }

      # Quaternion from rotation matrix (Shoemake).
      trace = rn[0][0] + rn[1][1] + rn[2][2]
      if trace > 0
        s = Math.sqrt(trace + 1.0) * 2 # s = 4*qa
        qa = 0.25 * s
        qb = (rn[2][1] - rn[1][2]) / s
        qc = (rn[0][2] - rn[2][0]) / s
        qd = (rn[1][0] - rn[0][1]) / s
      elsif rn[0][0] > rn[1][1] && rn[0][0] > rn[2][2]
        s = Math.sqrt(1.0 + rn[0][0] - rn[1][1] - rn[2][2]) * 2
        qa = (rn[2][1] - rn[1][2]) / s
        qb = 0.25 * s
        qc = (rn[0][1] + rn[1][0]) / s
        qd = (rn[0][2] + rn[2][0]) / s
      elsif rn[1][1] > rn[2][2]
        s = Math.sqrt(1.0 + rn[1][1] - rn[0][0] - rn[2][2]) * 2
        qa = (rn[0][2] - rn[2][0]) / s
        qb = (rn[0][1] + rn[1][0]) / s
        qc = 0.25 * s
        qd = (rn[1][2] + rn[2][1]) / s
      else
        s = Math.sqrt(1.0 + rn[2][2] - rn[0][0] - rn[1][1]) * 2
        qa = (rn[1][0] - rn[0][1]) / s
        qb = (rn[0][2] + rn[2][0]) / s
        qc = (rn[1][2] + rn[2][1]) / s
        qd = 0.25 * s
      end

      # NIfTI convention: qa must be >= 0; flip sign of (a,b,c,d) if needed.
      if qa < 0
        qb = -qb
        qc = -qc
        qd = -qd
      end

      [qb, qc, qd, qx, qy, qz]
    end

    def write_bytes(path, bytes)
      if path.to_s.end_with?(".gz")
        File.open(path, "wb") do |f|
          gz = Zlib::GzipWriter.new(f)
          gz.write(bytes)
          gz.close
        end
      else
        File.binwrite(path, bytes)
      end
    end
  end
end
