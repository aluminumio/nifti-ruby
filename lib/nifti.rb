# frozen_string_literal: true

require "zlib"
require "stringio"

require_relative "nifti/version"
require_relative "nifti/header"
require_relative "nifti/volume"

module Nifti
  class Error < StandardError; end
  class FormatError < Error; end
  class UnsupportedError < Error; end

  # Loads a NIfTI-1 single-file (.nii or .nii.gz) volume from disk.
  def self.load(path)
    bytes = read_all(path)
    Volume.from_bytes(bytes, source: path)
  end

  # Read the full contents, transparently decompressing if gzipped.
  def self.read_all(path)
    raw = File.binread(path)
    return raw unless raw.bytesize >= 2 && raw.byteslice(0, 2) == "\x1f\x8b".b

    Zlib::GzipReader.new(StringIO.new(raw)).read
  end
end
