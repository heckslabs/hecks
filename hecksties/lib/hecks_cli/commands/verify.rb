# Hecks::CLI verify command
#
# Runs Bluebook self-verification from the CLI.
#
#   hecks verify                        # progress (dots)
#   hecks verify --format documentation # verbose tree
#
Hecks::CLI.register_command(:verify, "Verify the Bluebook (the spec)",
  options: {
    format: { type: :string, default: "progress", desc: "Output format: progress or documentation" }
  }
) do
  bluebook = Dir[File.join(Dir.pwd, "*Bluebook")].first
  Kernel.load(bluebook) if bluebook
  require "hecks/chapters/verify"

  format = options[:format].to_sym
  Hecks::Chapters.verify(format: format)
rescue Hecks::Chapters::VerificationError => e
  say e.message, :red
  exit 1
end
