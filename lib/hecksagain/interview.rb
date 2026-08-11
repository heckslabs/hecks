require "hecksagain"

module Hecksagain
  # The discovery toolchain: a live session held against the language's own
  # self-hosted grammar. `Interview::Session` is the meta-domain half — see
  # `lib/hecksagain/framework/bluebook/interview.bluebook` for the domain
  # half, which is a real chapter like any other and needs no special
  # loading of its own.
  #
  # NOT required by `require "hecksagain"` itself. `Session` pulls in
  # `Bluebook::ModelCheck`, and `model_check.rb` is itself kept out of the
  # core boot chain (only `bin/model_check` and `fuzzing/properties.rb`
  # require it directly) — an existing, deliberate line this subsystem has
  # no reason to move. A project that never opens an interview never pays
  # for the checker.
  module Interview
  end
end

require_relative "interview/session"
require_relative "interview/lowering"
require_relative "interview/source"
require_relative "interview/writer"
require_relative "interview/shape"
