# frozen_string_literal: true

require "nifti"
require "yaml"

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.example_status_persistence_file_path = ".rspec_status"
end

module SpecPaths
  ROOT     = File.expand_path("..", __dir__)
  FIXTURES = File.join(ROOT, "spec", "fixtures")
  GOLDEN   = File.join(ROOT, "spec", "golden")

  def fixture(name)
    File.join(FIXTURES, "#{name}.nii.gz")
  end

  def golden(name, ext)
    File.join(GOLDEN, "#{name}.#{ext}")
  end

  def load_shape_golden(name)
    YAML.safe_load_file(golden(name, "shape.yaml"), permitted_classes: [Symbol])
  end

  def load_meta_golden(name)
    YAML.safe_load_file(golden(name, "meta.yaml"), permitted_classes: [Symbol, Float])
  end
end

RSpec.configure { |c| c.include SpecPaths }
