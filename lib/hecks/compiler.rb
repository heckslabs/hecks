# Hecks::Compiler
#
# Binary compiler for Hecks v0. Concatenates all framework source
# files in load order into a single self-contained Ruby script.
# The compiled binary boots Hecks with zero require_relative.
#
#   require "hecks/compiler"
#   Hecks::Compiler::BinaryCompiler.new.compile(output: "hecks_v0")
#
module Hecks
  module Compiler
  end
end

require_relative "compiler/source_collector"
require_relative "compiler/forward_declarations"
require_relative "compiler/bundle_writer"
require_relative "compiler/binary_compiler"
