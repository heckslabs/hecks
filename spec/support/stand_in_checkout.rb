require "tmpdir"
require "fileutils"

# A directory that stands in for a checkout: it holds an `exe/hecks` that is a shell script, so a
# spec can run "the checkout's own launcher" without booting a domain. The script writes what it
# was asked to the file `asked` and ends as the named gate does.
module StandInCheckout
  # What each stand-in gate prints and how it ends.
  GATES = {
    green:  ["echo '{\"state\": {\"status\": \"completed\"}}'", 0],
    red:    ["echo 'rubocop: 1 offense'", 1],
    silent: ["echo 'nothing ran'", 0]
  }.freeze

  # @param gate [Symbol] `:green`, `:red` or `:silent`
  # @yieldparam directory [String] the stand-in checkout
  # @return [Object] what the block answers
  def in_checkout(gate:)
    Dir.mktmpdir("hecks-stand-in-checkout") do |directory|
      write_launcher(File.realpath(directory), gate)
      yield File.realpath(directory)
    end
  end

  # Replaces the stand-in checkout's gate, as mending a branch would.
  #
  # @param directory [String] the stand-in checkout
  # @param gate [Symbol] `:green`, `:red` or `:silent`
  # @return [void]
  def write_launcher(directory, gate)
    says, status = GATES.fetch(gate)
    path = File.join(directory, "exe", "hecks")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "#!/bin/sh\necho \"$@\" > asked\n#{says}\nexit #{status}\n")
    File.chmod(0o755, path)
  end
end
