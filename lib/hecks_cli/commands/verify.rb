# Hecks::CLI verify command
#
# Runs Bluebook self-verification from the CLI.
#
#   hecks verify                        # progress (dots)
#   hecks verify --format documentation # verbose tree
#
Hecks::CLI.handle(:verify) do |inv|
  bluebook = Dir[File.join(Dir.pwd, "*Bluebook")].first
  Kernel.load(bluebook) if bluebook
  require "hecks/chapters/verify"

  format = options[:format].to_sym
  Hecks::Chapters.verify(format: format)
rescue Hecks::VerificationError => e
  say e.message, :red
  exit 1
end
