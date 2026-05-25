# frozen_string_literal: true

require_relative "lib/nifti/version"

Gem::Specification.new do |spec|
  spec.name        = "nifti-ruby"
  spec.version     = Nifti::VERSION
  spec.authors     = ["Jonathan Siegel"]
  spec.email       = ["jonathan@siegel.io"]

  spec.summary     = "Ruby reader for NIfTI-1 medical-imaging volumes"
  spec.description = "Pure-Ruby reader for the NIfTI-1 single-file format (.nii / .nii.gz), " \
                     "verified bit-identical against Python's nibabel."
  spec.homepage    = "https://github.com/aluminumio/nifti-ruby"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3.0"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md",
    "LICENSE",
    "nifti.gemspec"
  ]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", ">= 2.0"
  spec.add_development_dependency "rspec", "~> 3.13"
end
