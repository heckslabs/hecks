require "spec_helper"
require "hecks/bluebook/model_check"
require "open3"
require "tmpdir"

# The opt-in `client` profile of the model checker: it refuses the
# construct that answers wrongly without refusing, and changes nothing when
# the profile is not asked for.
#
# Each rule is tied to the bug it guards by a probe in "rules that retire with
# their bug": the probe runs the buggy code and asserts it still misbehaves,
# so the moment the bug is fixed that example fails and names the rule to
# delete. Delete the rule, its examples here, and its probe together.
RSpec.describe "the model checker's client profile" do
  SHOP = <<~BLUEBOOK.freeze
    Hecks.bluebook "ClientProfileShop" do
      vision "One owner, one widget aggregate, one read model per shape the client profile judges."
      core

      aggregate "Owner" do
        identified_by :number
        attribute :number, Number
        value_object "Number" do
          attribute :value, String
        end
        command "Enrol" do
          attribute :number, Number
        end
      end

      aggregate "Widget" do
        identified_by :number
        reference_to Owner
        attribute :number, Number
        attribute :group, Group
        value_object "Number" do
          attribute :value, String
        end
        value_object "Group" do
          attribute :name, String
        end
        command "Make" do
          attribute :number, Number
          attribute :group, Group
        end
      end

      read_model "WidgetsByGroup" do
        include Widget
        group_by :group
      end

      read_model "OwnerWidgets" do
        reference_to Owner
        include Owner
        include Widget
      end

      read_model "OwnerWidgetCount" do
        reference_to Owner
        include Owner
        include Widget
        count
      end
    end
  BLUEBOOK

  def build(projection: nil)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      eval(SHOP, TOPLEVEL_BINDING, "client_profile_shop.bluebook")
      Hecks.hecksagon("ClientProfileShop") do
        ClientProfileShop::Owner.persisted_by("Memory")
        ClientProfileShop::Widget.persisted_by("Memory")
        projected_by(projection) if projection
      end
    end
    registry
  end

  def profiled(registry, profile: :client)
    chapter = registry.bluebooks.values.first
    Hecks::Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name), profile: profile)
  end

  def subjects_for(findings, kind) = findings.select { |finding| finding.kind == kind }.map(&:subject)

  describe "without the profile" do
    it "adds no finding and leaves the others as they were" do
      registry = build(projection: "SqliteProjection")

      chapter = registry.bluebooks.values.first
      plain = profiled(registry, profile: nil)
      bare = Hecks::Bluebook::ModelCheck.call(chapter, hecksagon: registry.hecksagon(chapter.name))

      expect(plain.map(&:kind).grep(/\Aclient_/)).to be_empty
      expect(plain.map(&:to_s)).to eq(bare.map(&:to_s))
    end

    it "refuses a profile it does not know" do
      expect { profiled(build, profile: :strict_client) }.to raise_error(ArgumentError, /unknown profile/)
    end
  end

  describe "native read model pushdown (docs/1.0-readiness.md, known gap 2)" do
    it "refuses a rooted read model over an aggregate projected_by an adapter that answers natively" do
      findings = profiled(build(projection: "SqliteProjection"))

      expect(subjects_for(findings, :client_native_read_model)).to eq(["OwnerWidgets"])
      expect(findings.find { |f| f.kind == :client_native_read_model }.message).to include("docs/1.0-readiness.md")
    end

    it "is silent when the aggregate has no projection bind" do
      expect(subjects_for(profiled(build), :client_native_read_model)).to be_empty
    end

    it "is silent for a projection adapter that has no native path" do
      expect(subjects_for(profiled(build(projection: "SomethingElse")), :client_native_read_model)).to be_empty
    end

    it "is silent for a model the interpreter never pushes down" do
      findings = profiled(build(projection: "SqliteProjection"))

      expect(subjects_for(findings, :client_native_read_model)).not_to include("OwnerWidgetCount", "WidgetsByGroup")
    end

    # `bin/model_check` once loaded only the alphabetically first `*.hecksagon` in a directory,
    # so a `projected_by` in any later one was invisible to this rule.
    it "is reached from bin/model_check when the projected_by is in a later hecksagon file" do
      Dir.mktmpdir do |root|
        chapters = File.join(root, "shop", "bluebook")
        FileUtils.mkdir_p(chapters)
        File.write(File.join(chapters, "shop.bluebook"), SHOP)
        File.write(File.join(chapters, "a_wiring.hecksagon"), <<~RUBY)
          Hecks.hecksagon "ClientProfileShop" do
            ClientProfileShop::Owner.persisted_by("Memory")
            ClientProfileShop::Widget.persisted_by("Memory")
          end
        RUBY
        File.write(File.join(chapters, "shop.hecksagon"), <<~RUBY)
          Hecks.hecksagon "ClientProfileShop" do
            projected_by "SqliteProjection"
          end
        RUBY

        output, status = Open3.capture2e("bundle", "exec", "ruby", "bin/model_check", "--profile", "client",
                                         File.join(root, "shop"), chdir: InMemoryDomain::ROOT)

        expect(output).to include("client_native_read_model", "OwnerWidgets")
        expect(status.exitstatus).to eq(1)
      end
    end

    it "lists exactly the adapters whose Ruby class implements query_read_model" do
      defining = Dir[File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/**/*.rb")].select do |path|
        File.read(path).match?(/^\s*def query_read_model\b/)
      end
      implementers = defining.flat_map { |path| File.read(path).scan(/^\s*class (\w+)/).flatten }

      expect(Hecks::Bluebook::ModelCheck::ClientProfile::NATIVE_READ_MODEL_ADAPTERS).to match_array(implementers)
    end
  end

  # Each example here runs the buggy code the rule guards and expects it to
  # still misbehave. When one fails, the bug is fixed: delete the rule named in
  # the message, its examples above, this probe, and the tracker it cites.
  describe "rules that retire with their bug" do
    it "client_native_read_model: the readiness doc still lists the missing agreement gate" do
      readiness = File.read(File.join(InMemoryDomain::ROOT, "docs/1.0-readiness.md"))

      expect(readiness).to match(/^2\. \*\*Read models have no cross-engine agreement gate\./),
                           "docs/1.0-readiness.md no longer lists known gap 2 as open. If native and in-process " \
                           "read models are now checked for agreement, delete ClientProfile#native_read_model_findings, " \
                           "its examples, and this probe."
    end
  end
end
