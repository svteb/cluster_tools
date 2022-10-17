require "spec"
require "colorize"

ENV["CRYSTAL_ENV"] = "TEST"

# This forces use of cluster-tools manifest in the repo's tools dir when running specs.
ENV["USE_MANIFEST_SPECS_DIRECTORY"] = "yes"

