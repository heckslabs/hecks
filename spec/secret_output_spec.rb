require "spec_helper"
require "stringio"

# A value a world hands an adapter under a `secret` declaration never reaches what the launcher
# prints: `Secrets` holds it by name from the moment the bind's settings are read, and every
# refusal, note, result or exception message that passes a guarded stream shows `«secret:NAME»`
# instead. The password inside a `database` URL is held the same way.
RSpec.describe Hecks::Secrets do
  FAKE_TOKEN    = "FAKE-SECRET-TOKEN-7f3a".freeze
  FAKE_PASSWORD = "FAKE-DB-PASSWORD-91c".freeze

  def vault = Hecks::Bluebook::Adapter.new(name: "Vault", fields: [:database], secrets: [:token])

  def settings = { token: FAKE_TOKEN, database: "postgres://hecks:#{FAKE_PASSWORD}@localhost/held" }

  def guarded(out) = described_class.guarded(out)

  before { described_class.clear! }

  after { described_class.clear! }

  describe ".register_settings" do
    it "masks a declared secret wherever it appears in a text" do
      described_class.register_settings(vault, settings)
      expect(described_class.redact("refused: token #{FAKE_TOKEN} is wrong")).to eq("refused: token «secret:token» is wrong")
    end

    it "masks the password a database URL carries, declared or not" do
      described_class.register_settings(nil, settings)
      expect(described_class.redact("bad URI: #{settings[:database]}"))
        .to eq("bad URI: postgres://hecks:«secret:database password»@localhost/held")
    end

    it "leaves a field that is not a secret alone" do
      described_class.register_settings(Hecks::Bluebook::Adapter.new(name: "Heki", fields: [:dir]), dir: "tmp/held")
      expect(described_class.redact("writes to tmp/held")).to eq("writes to tmp/held")
    end

    it "holds nothing from an adapter the registry does not know, past a database password" do
      described_class.register_settings(nil, token: FAKE_TOKEN)
      expect(described_class.any?).to be(false)
    end
  end

  describe ".redact" do
    it "masks the longer value whole when one value contains another" do
      described_class.register("short", "abc")
      described_class.register("long", "xabcx")
      expect(described_class.redact("got xabcx and abc")).to eq("got «secret:long» and «secret:short»")
    end

    it "returns a non-String as it is" do
      described_class.register("token", FAKE_TOKEN)
      expect(described_class.redact(42)).to eq(42)
    end
  end

  describe "a guarded stream" do
    it "masks a line written with puts" do
      described_class.register("token", FAKE_TOKEN)
      out = StringIO.new
      guarded(out).puts("[hecks] token #{FAKE_TOKEN} refused")
      expect(out.string).to eq("[hecks] token «secret:token» refused\n")
    end

    it "masks a write, a print and an append" do
      described_class.register("token", FAKE_TOKEN)
      out = StringIO.new
      guarded(out).write(FAKE_TOKEN).then { guarded(out).print(" #{FAKE_TOKEN}") }.then { guarded(out) << " #{FAKE_TOKEN}" }
      expect(out.string).to eq("«secret:token» «secret:token» «secret:token»")
    end

    it "masks what warn and abort write, since both write to the stream" do
      described_class.register("token", FAKE_TOKEN)
      out = guarded(StringIO.new)
      out.puts(["a #{FAKE_TOKEN}", "b #{FAKE_TOKEN}"])
      expect(out.__getobj__.string).to eq("a «secret:token»\nb «secret:token»\n")
    end

    it "is not guarded twice" do
      once = guarded(StringIO.new)
      expect(guarded(once)).to be(once)
    end
  end

  describe "a booted world" do
    def vault_world
      Hecks.adapter("SecretVault") do
        port "persistence"
        field :database
        secret :token
      end
      Hecks.world("Held") { persisted_by("SecretVault") { token FAKE_TOKEN } }
    end

    it "holds the secret from the moment the bind's settings are read" do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) { vault_world }
      registry.binding_settings("Held", "persisted_by", "SecretVault")
      expect(described_class.redact("world says #{FAKE_TOKEN}")).to eq("world says «secret:token»")
    end
  end
end
