require "spec_helper"

# A declared `pattern:` is enforced against the whole value: Ruby's line anchors would let
# `"ok\n../../evil"` satisfy `^[a-z]+$`, while Rust's `regex` reads `^`/`$` as text anchors.
RSpec.describe "whole-string pattern enforcement" do
  describe Hecks::Bluebook::PatternSubset, ".whole_string" do
    {
      "^[a-z]+$"   => '\A[a-z]+\z',
      '\A[a-z]+\z' => '\A[a-z]+\z',
      "^(a|b)$"    => '\A(a|b)\z',
      '[^ \t\n\r]' => '[^ \t\n\r]',
      "[$^]+"      => "[$^]+",
      'a\$b'       => 'a\$b',
      '^[^\]]$'    => '\A[^\]]\z'
    }.each do |source, rewritten|
      it "rewrites #{source} as #{rewritten}" do
        expect(described_class.whole_string(source)).to eq(rewritten)
      end
    end
  end

  describe "enforcement, against a corpus value object" do
    let(:runtime) { Hecks.boot(File.join(InMemoryDomain::ROOT, "examples/banking")) }
    let(:email) { runtime.registry.bluebook("Banking").aggregate("Customer").value_object("EmailAddress") }

    it "refuses a value whose later line escapes an anchored pattern" do
      expect { Hecks::Runtime::Value.build(email, address: "a@b.co\nnot an address") }
        .to raise_error(Hecks::Runtime::TypeMismatch)
    end

    it "still accepts a value that matches as a whole" do
      expect { Hecks::Runtime::Value.build(email, address: "a@b.co") }.not_to raise_error
    end
  end

  describe "the Deploy tenant value objects" do
    let(:runtime) { Hecks.boot(File.expand_path("../lib/hecks/deploy", __dir__)) }
    let(:tenant) { runtime.registry.bluebook("Deploy").aggregate("Tenant") }

    %w[Slug Schema DatabaseName].each do |name|
      it "declares #{name} with whole-string anchors" do
        pattern = tenant.value_object(name).attributes.first.pattern

        expect(pattern).to start_with('\A').and end_with('\z')
      end
    end

    it "refuses a slug carrying a second line" do
      expect { Hecks::Runtime::Value.build(tenant.value_object("Slug"), value: "ok\n../../evil") }
        .to raise_error(Hecks::Runtime::TypeMismatch)
    end
  end
end
