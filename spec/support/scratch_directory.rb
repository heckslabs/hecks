require "tmpdir"

# A temporary directory for every example of a group, removed afterwards.
#
#   RSpec.describe "..." do
#     scratch_directory :dir
#     scratch_directory :root, "codegen-run"
#
# `name` is the instance variable the example reads the directory from; `prefix` names the
# directory on disk (see `Dir.mktmpdir`).
module ScratchDirectory
  def scratch_directory(name = :dir, *prefix)
    around do |example|
      Dir.mktmpdir(*prefix) do |dir|
        instance_variable_set(:"@#{name}", dir)
        example.run
      end
    end
  end
end

RSpec.configure { |config| config.extend ScratchDirectory }
