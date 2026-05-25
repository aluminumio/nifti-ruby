# frozen_string_literal: true

module Nifti
  # NIfTI-1 header (348 bytes, fixed layout). Spec: https://nifti.nimh.nih.gov/nifti-1
  #
  # Field map (offset : type : name):
  #   0   i4        sizeof_hdr      (must be 348)
  #   4   c10       data_type       unused, kept for ANALYZE compatibility
  #   14  c18       db_name         unused
  #   32  i4        extents         unused
  #   36  i2        session_error   unused
  #   38  c1        regular         unused
  #   39  c1        dim_info        MRI slice ordering
  #   40  i2[8]     dim             data array dimensions
  #   56  f4        intent_p1
  #   60  f4        intent_p2
  #   64  f4        intent_p3
  #   68  i2        intent_code
  #   70  i2        datatype        DT_* constant
  #   72  i2        bitpix          bits per voxel
  #   74  i2        slice_start
  #   76  f4[8]     pixdim          grid spacings (pixdim[0] is qfac)
  #   108 f4        vox_offset      byte offset into .nii where voxel data starts
  #   112 f4        scl_slope
  #   116 f4        scl_inter
  #   120 i2        slice_end
  #   122 c1        slice_code
  #   123 c1        xyzt_units
  #   124 f4        cal_max
  #   128 f4        cal_min
  #   132 f4        slice_duration
  #   136 f4        toffset
  #   140 i4        glmax           unused
  #   144 i4        glmin           unused
  #   148 c80       descrip
  #   228 c24       aux_file
  #   252 i2        qform_code
  #   254 i2        sform_code
  #   256 f4        quatern_b
  #   260 f4        quatern_c
  #   264 f4        quatern_d
  #   268 f4        qoffset_x
  #   272 f4        qoffset_y
  #   276 f4        qoffset_z
  #   280 f4[4]     srow_x
  #   296 f4[4]     srow_y
  #   312 f4[4]     srow_z
  #   328 c16       intent_name
  #   344 c4        magic           "ni1\0" for paired hdr/img, "n+1\0" for single file
  #   ----- end (348 bytes) -----
  module Header
    SIZE = 348

    # NIfTI datatype codes -> internal symbols.
    DATATYPE = {
      0   => :unknown,
      1   => :bit,
      2   => :uint8,
      4   => :int16,
      8   => :int32,
      16  => :float32,
      32  => :complex64,
      64  => :float64,
      128 => :rgb24,
      256 => :int8,
      512 => :uint16,
      768 => :uint32,
      1024 => :int64,
      1280 => :uint64,
      1536 => :float128,
      1792 => :complex128,
      2048 => :complex256,
      2304 => :rgba32
    }.freeze

    # Byte size per voxel by symbol. Used to size voxel_bytes correctly.
    BYTES_PER_VOXEL = {
      bit: nil, # 1-bit packed, unsupported in Phase 1
      uint8: 1, int8: 1,
      int16: 2, uint16: 2,
      int32: 4, uint32: 4, float32: 4,
      int64: 8, uint64: 8, float64: 8, complex64: 8,
      complex128: 16, float128: 16,
      complex256: 32,
      rgb24: 3, rgba32: 4
    }.freeze

    module_function

    # Decodes a 348-byte NIfTI-1 header. `byte_order` is "<" (little-endian)
    # or ">" (big-endian); detected by the caller from sizeof_hdr.
    def decode(blob, byte_order)
      raise FormatError, "header blob must be 348 bytes" unless blob.bytesize == SIZE

      # Build little/big specific unpack format strings.
      # Ruby pack/unpack: l<=int32 LE, l>=int32 BE; s< s>; e=f32 LE g=f32 BE; e/g for doubles
      i4 = byte_order == "<" ? "l<" : "l>"
      i2 = byte_order == "<" ? "s<" : "s>"
      f4 = byte_order == "<" ? "e"  : "g"

      h = {}
      h[:sizeof_hdr]      = blob.unpack1("@0#{i4}")
      h[:data_type]       = blob.byteslice(4, 10).unpack1("A*")
      h[:db_name]         = blob.byteslice(14, 18).unpack1("A*")
      h[:extents]         = blob.unpack1("@32#{i4}")
      h[:session_error]   = blob.unpack1("@36#{i2}")
      h[:regular]         = blob.byteslice(38, 1).unpack1("A*")
      h[:dim_info]        = blob.byteslice(39, 1).unpack1("C")
      h[:dim]             = blob.byteslice(40, 16).unpack("#{i2}8")
      h[:intent_p1]       = blob.unpack1("@56#{f4}")
      h[:intent_p2]       = blob.unpack1("@60#{f4}")
      h[:intent_p3]       = blob.unpack1("@64#{f4}")
      h[:intent_code]     = blob.unpack1("@68#{i2}")
      h[:datatype]        = blob.unpack1("@70#{i2}")
      h[:bitpix]          = blob.unpack1("@72#{i2}")
      h[:slice_start]     = blob.unpack1("@74#{i2}")
      h[:pixdim]          = blob.byteslice(76, 32).unpack("#{f4}8")
      h[:vox_offset]      = blob.unpack1("@108#{f4}")
      h[:scl_slope]       = blob.unpack1("@112#{f4}")
      h[:scl_inter]       = blob.unpack1("@116#{f4}")
      h[:slice_end]       = blob.unpack1("@120#{i2}")
      h[:slice_code]      = blob.byteslice(122, 1).unpack1("C")
      h[:xyzt_units]      = blob.byteslice(123, 1).unpack1("C")
      h[:cal_max]         = blob.unpack1("@124#{f4}")
      h[:cal_min]         = blob.unpack1("@128#{f4}")
      h[:slice_duration]  = blob.unpack1("@132#{f4}")
      h[:toffset]         = blob.unpack1("@136#{f4}")
      h[:glmax]           = blob.unpack1("@140#{i4}")
      h[:glmin]           = blob.unpack1("@144#{i4}")
      h[:descrip]         = blob.byteslice(148, 80).unpack1("A*")
      h[:aux_file]        = blob.byteslice(228, 24).unpack1("A*")
      h[:qform_code]      = blob.unpack1("@252#{i2}")
      h[:sform_code]      = blob.unpack1("@254#{i2}")
      h[:quatern_b]       = blob.unpack1("@256#{f4}")
      h[:quatern_c]       = blob.unpack1("@260#{f4}")
      h[:quatern_d]       = blob.unpack1("@264#{f4}")
      h[:qoffset_x]       = blob.unpack1("@268#{f4}")
      h[:qoffset_y]       = blob.unpack1("@272#{f4}")
      h[:qoffset_z]       = blob.unpack1("@276#{f4}")
      h[:srow_x]          = blob.byteslice(280, 16).unpack("#{f4}4")
      h[:srow_y]          = blob.byteslice(296, 16).unpack("#{f4}4")
      h[:srow_z]          = blob.byteslice(312, 16).unpack("#{f4}4")
      h[:intent_name]     = blob.byteslice(328, 16).unpack1("A*")
      h[:magic]           = blob.byteslice(344, 4).unpack1("A*")
      h[:byte_order]      = byte_order
      h
    end
  end
end
