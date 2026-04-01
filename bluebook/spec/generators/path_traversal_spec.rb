# bluebook/spec/generators/path_traversal_spec.rb
#
# Specs for Hecks::Utils.safe_path! — path traversal prevention for generator
# file writers. Covers the attack vectors that could escape the output directory.
require "spec_helper"
require "tmpdir"

RSpec.describe "Generator path traversal protection" do
  let(:root) { Dir.mktmpdir }

  after { FileUtils.rm_rf(root) }

  describe "Hecks::Utils.safe_path!" do
    context "when the relative path contains ../" do
      it "raises PathTraversalDetected" do
        expect {
          Hecks::Utils.safe_path!(root, "../etc/passwd")
        }.to raise_error(Hecks::PathTraversalDetected, /outside/)
      end
    end

    context "when the relative path is absolute" do
      it "raises PathTraversalDetected" do
        expect {
          Hecks::Utils.safe_path!(root, "/etc/passwd")
        }.to raise_error(Hecks::PathTraversalDetected, /outside/)
      end
    end

    context "when the relative path contains a null byte" do
      it "raises PathTraversalDetected" do
        expect {
          Hecks::Utils.safe_path!(root, "safe\0../evil")
        }.to raise_error(Hecks::PathTraversalDetected, /outside/)
      end
    end

    context "when the relative path is a safe nested path" do
      it "returns the absolute resolved path" do
        result = Hecks::Utils.safe_path!(root, "lib/pizza/pizza.rb")
        expect(result).to eq(File.join(root, "lib/pizza/pizza.rb"))
      end
    end

    context "when a domain name contains ../ traversal" do
      it "raises PathTraversalDetected" do
        malicious_relative = "lib/../../etc/passwd"
        expect {
          Hecks::Utils.safe_path!(root, malicious_relative)
        }.to raise_error(Hecks::PathTraversalDetected)
      end
    end

    context "when an aggregate name contains traversal segments" do
      it "raises PathTraversalDetected" do
        malicious_relative = "lib/my_domain/../../../shadow"
        expect {
          Hecks::Utils.safe_path!(root, malicious_relative)
        }.to raise_error(Hecks::PathTraversalDetected)
      end
    end
  end

  describe "Hecks::PathTraversalDetected" do
    it "exposes attempted_path and output_dir" do
      error = Hecks::PathTraversalDetected.new(
        attempted_path: "../evil",
        output_dir: "/tmp/safe"
      )
      expect(error.attempted_path).to eq("../evil")
      expect(error.output_dir).to eq("/tmp/safe")
      expect(error.message).to include("../evil")
      expect(error.message).to include("/tmp/safe")
    end

    it "is a subclass of Hecks::Error" do
      expect(Hecks::PathTraversalDetected.ancestors).to include(Hecks::Error)
    end
  end
end
