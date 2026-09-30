require "spec_helper"
require "open3"

# Booting the Hecks chapter attaches gem chapters (Deploy, Tenancy, QualityControl, the language).
# Their aggregates (`Query`, `Port`, `Policy`, `Target`...) must not become top-level constants,
# or a domain booted later that declares such an aggregate meets the chapter's module instead.
RSpec.describe "Facade install of attached chapters" do
  # Run in a fresh process: constants installed by earlier examples would mask the delta.
  let(:script) do
    <<~RUBY
      $LOAD_PATH.unshift File.expand_path("lib")
      require "hecks"
      before = Object.constants
      Hecks.boot("lib/hecks/hecks")
      puts (Object.constants - before).sort
    RUBY
  end

  it "adds no attached chapter or chapter aggregate as a top-level constant" do
    out, status = Open3.capture2e({ "HECKS_ENVIRONMENT" => "memory" }, RbConfig.ruby, "-e", script,
                                  chdir: File.expand_path("../..", __dir__))
    added = out.lines.map(&:strip).grep(/\A[A-Z]\w*\z/)

    expect(status).to be_success
    leaked = added & %w[Query Command Policy Port Adapter Aggregate Entity ValueObject Syntax
                        Vocabulary Target Ticket Bug Patch Improvement Angle Sweep Clearance
                        Operator Tenant Recipe World Wiring Translation Deploy Tenancy
                        QualityControl Bluebook Hecksagon Expression]
    expect(leaked).to eq([])
  end
end
