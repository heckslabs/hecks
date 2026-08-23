module Hecksagain
  # The era-translation toolchain: scaffold drafts a translation from two
  # eras' shapes, audit judges a written one, reattest re-seals it.
  module Translation
  end
end

require_relative "translation/rule_compiler"
require_relative "translation/scaffold"
require_relative "translation/audit"
require_relative "translation/reattest"
