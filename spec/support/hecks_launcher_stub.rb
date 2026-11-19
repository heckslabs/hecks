# frozen_string_literal: true

require "fileutils"
require "hecks/hecks/adapters/checkout_gate"

# A stand-in for the hecks launcher in a throwaway repository, so a verification of its commits
# reads it as a hecks checkout (`MainIntegration::Repository#launcher?`). The spec commits it.
module HecksLauncherStub
  module_function

  # Writes the launcher stub into a repository's working tree.
  #
  # @param repo [String] the repository's directory
  # @return [String] the stub's path
  def place(repo)
    path = File.join(repo, Hecks::Adapters::CheckoutGate::LAUNCHER)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\n")
    path
  end
end
