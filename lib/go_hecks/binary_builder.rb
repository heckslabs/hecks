# GoHecks::BinaryBuilder
#
# Compiles a domain into a native binary via the Go target.
# Generates Go source in a temp directory, runs go build,
# and copies the binary to the output directory.
#
#   GoHecks::BinaryBuilder.build(domain, output_dir: "bin")
#
require "tmpdir"

module GoHecks
  module BinaryBuilder
    include HecksTemplating::NamingHelpers

    def self.build(domain, output_dir: "bin")
      valid, errors = Hecks.validate(domain)
      raise Hecks::ValidationError.for_domain(errors) unless valid

      snake = domain_snake_name(domain.name)
      Dir.mktmpdir("hecks_binary") do |tmpdir|
        go_root = ProjectGenerator.new(domain, output_dir: tmpdir).generate
        cmd_dir = Dir[File.join(go_root, "cmd", "*")].first
        system("cd #{go_root} && go mod tidy 2>/dev/null") || raise("go mod tidy failed")
        binary_path = File.join(go_root, snake)
        system("cd #{go_root} && go build -o #{binary_path} ./cmd/#{File.basename(cmd_dir)}/") || raise("go build failed")
        FileUtils.mkdir_p(output_dir)
        dest = File.join(File.expand_path(output_dir), snake)
        FileUtils.cp(binary_path, dest)
        File.chmod(0o755, dest)
        dest
      end
    end

    extend self
  end
end
