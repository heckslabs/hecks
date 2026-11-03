require "hecks"
require_relative "fixtures/sequential_identity"

# The membership rules a site's host enforces, as the Hecks-shipped SiteMembership bluebook declares
# them. A local boot with Memory persistence and no real store, journal or clock: the facts the
# adapter would read (the other people, the caller's role, whether a window ended) are passed in.
RSpec.describe "SiteMembership" do
  # The membership rule requires an identity bluebook beside it, as identity_spec boots it.
  SPEC_FILES = [
    InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
    InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER,
    File.expand_path("../lib/hecks/ports/identity_generation.port", __dir__),
    File.expand_path("fixtures/sequential_identity.adapter", __dir__),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/site_membership.bluebook"),
    File.join(InMemoryDomain::ROOT, "lib/hecks/framework/bluebook/identity.bluebook")
  ].freeze

  # What the adapter hands a command when it knows nothing yet: a lone site, a caller who is an admin.
  FACTS = {
    caller_role: "Admin", caller: "root@example.com", window_ended: "no", window_days: 0, window_ends_at: "",
    others_open_admins: 0, others_admins: 0, others_active_admins: 0
  }.freeze

  # The arguments each command declares; a command refuses one it does not.
  TAKES = {
    "Grant"   => %i[new_role window_days window_ends_at others_open_admins others_admins],
    "SetRole" => %i[new_role caller_role window_ended others_active_admins others_open_admins others_admins],
    "Disable" => %i[caller caller_role window_ended others_active_admins others_open_admins],
    "Enable"  => %i[caller_role],
    "Delete"  => %i[caller_role]
  }.freeze

  AMY = "amy@example.com".freeze
  LATER = "2031-01-01T00:00:00Z".freeze

  def declare_hecksagons
    Hecks.hecksagon("SiteMembership") do
      attaches "Identity"
      SiteMembership::Membership.persisted_by("Memory")
    end
    declare_identity_hecksagons
  end

  def declare_identity_hecksagons
    Hecks.hecksagon("Identity") do
      attaches "Governance"
      Identity::Identity.persisted_by("Memory")
      Identity::ExternalIdentifier.persisted_by("Memory")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def boot
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      SPEC_FILES.each { |file| Kernel.load(file) }
      declare_hecksagons
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot }

  def admit(email = AMY, name: "Amy")
    runtime.dispatch_flat("SiteMembership::Membership.Admit", email: { value: email }, name: { value: name })
  end

  # Dispatches `verb` on `email` with the facts given over the defaults, each wrapped as a value.
  def act(verb, email, **facts)
    facts[:new_role] = facts.delete(:role) if facts.key?(:role)
    given = FACTS.merge(facts).slice(*TAKES.fetch(verb))
    args = { id: email }.merge(given.transform_values { |fact| { value: fact } })
    runtime.dispatch_flat("SiteMembership::Membership.#{verb}", args)
  end

  def grant(**facts) = act("Grant", AMY, **facts)
  def set_role(role, **facts) = act("SetRole", AMY, new_role: role, **facts)
  def disable(**facts) = act("Disable", AMY, **facts)
  def enable(**facts) = act("Enable", AMY, **facts)
  def delete(**facts) = act("Delete", AMY, **facts)

  def event_names(result) = result.events.map(&:name)

  def aggregate = runtime.registry.bluebook("SiteMembership").aggregate("Membership")

  def state = runtime.registry.repository("SiteMembership", aggregate).find(AMY).state

  def field(name) = state[name].value

  def verbs
    declaration = Hecks::Framework.declaration("SiteMembership")
    %i[admit grant people].to_h { |key| [key, declaration.provided_verb("membership", key)] }
  end

  it "is a framework member that provides the three verbs the membership contract asks for", :aggregate_failures do
    expect(Hecks::Framework.providers_of("membership")).to eq(["SiteMembership"])
    expect(verbs.values).to eq(%w[Admit Grant People].map { |verb| "SiteMembership::Membership.#{verb}" })
  end

  it "admits a person with no role and no window", :aggregate_failures do
    expect(event_names(admit)).to eq(["PersonAdmitted"])
    expect(field(:role)).to eq("")
  end

  it "refuses to admit the same email twice" do
    admit
    expect { admit }.to raise_error(Hecks::Runtime::AlreadyExists)
  end

  describe "roles" do
    before { admit }

    it "grants Admin when no role is named" do
      grant
      expect(field(:role)).to eq("Admin")
    end

    it "grants only Admin, Owner or Member", :aggregate_failures do
      %w[Admin Owner Member].each { |role| expect { grant(role: role, others_open_admins: 1) }.not_to raise_error }
      expect { grant(role: "Janitor", others_open_admins: 1) }.to raise_error(Hecks::Refused)
    end

    it "lets any admin grant Owner, and an Owner is an admin too", :aggregate_failures do
      grant(role: "Member", others_open_admins: 1)
      expect(event_names(set_role("Owner", caller_role: "Admin"))).to eq(["RoleSet"])
      expect(event_names(set_role("Admin", caller_role: "Owner"))).to eq(["RoleSet"])
    end

    it "lets only an admin set a role", :aggregate_failures do
      grant(role: "Member", others_open_admins: 1)
      ["Member", ""].each do |caller_role|
        expect { set_role("Owner", caller_role: caller_role) }.to raise_error(Hecks::Runtime::GivenNotMet)
      end
    end

    it "refuses to demote the only active admin, and allows it when another remains", :aggregate_failures do
      grant(role: "Admin", others_open_admins: 1)
      expect { set_role("Member", others_open_admins: 1) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /keeps an active admin/)
      expect(event_names(set_role("Member", others_active_admins: 1, others_open_admins: 1))).to eq(["RoleSet"])
    end

    it "counts an admin whose window ended as not active" do
      grant(role: "Admin", window_days: 5, window_ends_at: LATER, others_open_admins: 1, others_admins: 1)
      expect(event_names(set_role("Member", window_ended: "yes", others_open_admins: 1))).to eq(["RoleSet"])
    end
  end

  describe "access windows" do
    before { admit }

    it "takes 1 to 365 days, or none", :aggregate_failures do
      [1, 365].each { |days| expect { grant(role: "Member", window_days: days, window_ends_at: LATER) }.not_to raise_error }
      [366, -1].each do |days|
        expect { grant(role: "Member", window_days: days, window_ends_at: LATER) }
          .to raise_error(Hecks::Runtime::GivenNotMet, /1 to 365 days/)
      end
    end

    it "sets the end the adapter computed" do
      grant(role: "Member", window_days: 7, window_ends_at: LATER)
      expect(field(:access_expires_at)).to eq(LATER)
    end

    it "does not read an unreadable end: only an instant is a window" do
      expect { grant(role: "Member", window_days: 7, window_ends_at: "soon") }.to raise_error(Hecks::Refused)
    end

    it "replaces the old window when granted again", :aggregate_failures do
      grant(role: "Member", window_days: 7, window_ends_at: LATER)
      grant(role: "Member", window_days: 30, window_ends_at: "2032-01-01T00:00:00Z")
      expect(field(:access_expires_at)).to eq("2032-01-01T00:00:00Z")
    end

    it "clears the window on a plain grant" do
      grant(role: "Member", window_days: 7, window_ends_at: LATER)
      grant(role: "Member")
      expect(field(:access_expires_at)).to eq("")
    end
  end

  describe "a site keeps an admin with no end date" do
    before { admit }

    it "refuses the site's first admin when it carries an end date" do
      expect { grant(role: "Admin", window_days: 7, window_ends_at: LATER) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /first admin/)
    end

    it "allows a windowed admin once another admin has no end date" do
      result = grant(role: "Admin", window_days: 7, window_ends_at: LATER, others_open_admins: 1, others_admins: 1)
      expect(event_names(result)).to eq(["AccessGranted"])
    end

    it "refuses a change that takes the last open-ended admin off that footing", :aggregate_failures do
      grant(role: "Admin")
      expect { grant(role: "Admin", window_days: 7, window_ends_at: LATER, others_admins: 1) }
        .to raise_error(Hecks::Runtime::GivenNotMet, /no end date/)
      expect { grant(role: "Member", others_admins: 1) }.to raise_error(Hecks::Runtime::GivenNotMet, /no end date/)
    end

    it "does not make a site with admins but no open-ended one worse" do
      grant(role: "Admin", window_days: 7, window_ends_at: LATER, others_open_admins: 1, others_admins: 1)
      expect { grant(role: "Admin", window_days: 9, window_ends_at: LATER, others_admins: 1) }.not_to raise_error
    end

    it "refuses to disable the last open-ended admin even when a windowed one remains" do
      grant(role: "Admin")
      expect { disable(others_active_admins: 1) }.to raise_error(Hecks::Runtime::GivenNotMet, /no end date/)
    end
  end

  describe "disable, enable, delete" do
    before do
      admit
      grant(role: "Admin", others_open_admins: 1)
    end

    let(:others) { { others_active_admins: 1, others_open_admins: 1 } }

    it "keeps the role when disabled", :aggregate_failures do
      disable(**others)
      expect(state[:status]).to eq("disabled")
      expect(field(:role)).to eq("Admin")
    end

    it "restores the same role when enabled again", :aggregate_failures do
      disable(**others)
      enable
      expect(state[:status]).to eq("admitted")
      expect(field(:role)).to eq("Admin")
    end

    it "refuses an admin who disables themselves" do
      expect { disable(caller: AMY, **others) }.to raise_error(Hecks::Runtime::GivenNotMet, /cannot disable themselves/)
    end

    it "refuses the last active admin, and the last open-ended one", :aggregate_failures do
      expect { disable(others_open_admins: 1) }.to raise_error(Hecks::Runtime::GivenNotMet, /keeps an active admin/)
      expect { disable(others_active_admins: 1) }.to raise_error(Hecks::Runtime::GivenNotMet, /no end date/)
    end

    it "lets only an active admin disable, enable or delete", :aggregate_failures do
      expect { disable(caller_role: "", **others) }.to raise_error(Hecks::Runtime::GivenNotMet)
      disable(**others)
      expect { enable(caller_role: "Member") }.to raise_error(Hecks::Runtime::GivenNotMet)
      expect { delete(caller_role: "Member") }.to raise_error(Hecks::Runtime::GivenNotMet)
    end

    it "deletes only a disabled person", :aggregate_failures do
      expect { delete }.to raise_error(Hecks::Runtime::LifecycleRefused)
      disable(**others)
      expect(event_names(delete)).to eq(["PersonDeleted"])
    end

    it "keeps a deleted person's row", :aggregate_failures do
      disable(**others)
      delete
      expect(state[:status]).to eq("deleted")
      expect(field(:role)).to eq("Admin")
    end

    it "gives a deleted person no way back", :aggregate_failures do
      disable(**others)
      delete
      expect { enable }.to raise_error(Hecks::Runtime::LifecycleRefused)
      expect { disable(**others) }.to raise_error(Hecks::Runtime::LifecycleRefused)
    end
  end
end
