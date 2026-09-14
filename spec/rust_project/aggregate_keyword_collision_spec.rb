require "spec_helper"
require "open3"
require "tmpdir"

# BUG#124 -- an aggregate whose snake-case name is a Rust keyword
# (qa/stress_domains/generated_keyword_aggregate's own "Crate") used to
# project to Rust that does not compile: bin/project_rust guarded only
# the DOMAIN name against RUST_KEYWORDS, so `pub mod crate;` (the
# aggregate's own generated module declaration, `a[:name].downcase` in
# domain_generator.rb) reached rustc as literal, un-escapable broken
# syntax -- 49 compile errors (E0433 "crate in paths can only be used in
# start position", E0282 cascades from there).
#
# `.valid_aggregate_mod_name?`/`rust_ident_field`'s own unit specs
# (naming_landmines_spec.rb) prove the STRING-LEVEL fix directly and
# fast; this spec is the end-to-end proof that `bin/project_rust`
# ACTUALLY refuses, cleanly, before ever reaching rustc, run as a real
# subprocess the same way the original finding did
# (bin/qa_generated_domains --rust). No `HECKS_RUST_DIR` scratch crate
# copy is needed -- the new guard fires before bin/project_rust ever
# reads rust/Cargo.toml, so a bare empty tmp dir is enough to prove it
# never gets that far.
RSpec.describe "bin/project_rust refuses a keyword-colliding aggregate name (BUG#124)" do
  # `ROOT`/`STRESS_DOMAIN` are deliberately instance methods, not top-level
  # constants -- spec/load_hygiene_spec.rb refuses any two spec files that
  # disagree about a top-level constant's own value, and `ROOT` is already
  # a well-trodden name across this suite (see oidc_manifest_spec.rb).
  def root = File.expand_path("../..", __dir__)
  def stress_domain = File.join(root, "qa/stress_domains/generated_keyword_aggregate")

  it "declares an aggregate literally named Crate -- the exact BUG#124 shape" do
    bluebook = File.read(File.join(stress_domain, "bluebook/generated_keyword_aggregate.bluebook"))
    expect(bluebook).to match(/aggregate\s+"Crate"/)
  end

  it "refuses cleanly, before writing any broken generated code, instead of emitting Rust that fails to compile" do
    Dir.mktmpdir("bug124-project-rust-spec") do |scratch_rust_dir|
      stdout, status = Open3.capture2e(
        { "HECKS_RUST_DIR" => scratch_rust_dir },
        "bundle", "exec", "ruby", File.join(root, "bin/project_rust"), stress_domain,
        chdir: root
      )

      expect(status.success?).to be(false),
                                 "expected bin/project_rust to refuse a domain with a Crate aggregate, " \
                                 "but it exited 0:\n#{stdout}"
      expect(stdout).to include("Crate")
      expect(stdout).to match(/keyword/i)
      # NEVER REACHES rustc -- the failure is bin/project_rust's own
      # RuntimeError, not a downstream compile error. If this ever
      # started including an E04.. code instead, the guard moved (or
      # broke) and generation is reaching codegen again.
      expect(stdout).not_to match(/E04\d\d/)

      # THE SCRATCH CRATE'S OWN generated/ tree for THIS domain has no
      # generated .rs FILE in it -- proving the guard fired before any
      # per-aggregate file for the colliding domain was written, not
      # merely before a LATER step. `WriteIfChanged.push_directory`
      # mkdir_p's the directory itself before DomainGenerator.call ever
      # runs (tracking setup, unrelated to this guard), so the directory
      # existing is expected -- an .rs file inside it would not be.
      target_dir = File.join(scratch_rust_dir, "src/generated/generated_keyword_aggregate")
      rs_files = Dir.exist?(target_dir) ? Dir.glob(File.join(target_dir, "**/*.rs")) : []
      expect(rs_files).to be_empty,
                          "expected no generated .rs files for the refused domain, found #{rs_files.inspect}"
    end
  end
end
