require "spec_helper"
require_relative "support/legacy_dispatch_sites"

# The deprecation's own worklist, held exactly (roadmap I3). Passing command
# facts to `dispatch`/`dispatch_port` as loose keyword arguments is deprecated
# — the shape behind nine past routing bugs, because the receiver's identity
# and the command's facts arrive in one undifferentiated bag. spec_helper.rb
# already makes a new one raise; this is the other half, and it is static, so
# it also covers a call site no run in the suite ever reaches.
#
# The counts live in spec/support/legacy_dispatch_sites.rb, next to the
# explanation of which ones no rewrite is sound for.
RSpec.describe "loose keyword facts in dispatch" do
  it "is confined to the files that already had them, and no more" do
    found = LegacyDispatchSites.scan
    caps  = LegacyDispatchSites::CAPS

    grown = found.filter_map do |path, count|
      "#{path}: #{count} loose call sites, #{caps.fetch(path, 0)} counted" if count > caps.fetch(path, 0)
    end
    expect(grown).to be_empty,
                     "a loose keyword dispatch appeared where none was counted — write the facts as " \
                     "`with: { ... }` with the receiver identity in `to:`:\n  #{grown.join("\n  ")}"

    # The other side of the ratchet: a site that was converted cannot come
    # back under cover of a count nothing spends any more.
    stale = caps.filter_map do |path, count|
      "#{path}: #{found.fetch(path, 0)} left, #{count} counted" if found.fetch(path, 0) < count
    end
    expect(stale).to be_empty,
                     "fewer loose call sites than counted — lower the count in " \
                     "spec/support/legacy_dispatch_sites.rb:\n  #{stale.join("\n  ")}"
  end

  # The framework's own doors hand their argument bag to `dispatch_flat`, so
  # a loose call arriving through `Hecks::Router`, the namespace shortcut, the
  # forms app, the CLI/JSON doors or a reaction re-entry is reported at the
  # caller's line. Nothing under lib/ may reintroduce a loose call of its own,
  # or the deprecation would name a line its reader cannot change.
  #
  # The three files pinned here are not dispatcher calls — they forward to a
  # different door of the same name, which only reads the same to a parser:
  # `Router.dispatch(address, **args)` and the namespace shortcut's own
  # `method_missing` hand their keywords to `Router#dispatch`, and
  # `Storehouse.dispatch(runtime:, command:, args:)` is Storehouse's own
  # keyword API. Each ends at a `dispatch_flat` call, not a loose one.
  it "is gone from the framework itself" do
    inside = Dir.glob(File.join(LegacyDispatchSites::ROOT, "lib/**/*.rb"))
                .select { |path| LegacyDispatchSites.count_in(path).positive? }
                .map { |path| LegacyDispatchSites.relative(path) }
                .sort

    expect(inside).to eq(["lib/hecks/router.rb", "lib/hecks/router/namespace_installer.rb",
                          "lib/hecks/storehouse.rb"]),
                      "lib/ dispatches with loose keyword facts — hand the argument bag to " \
                      "`Dispatcher#dispatch_flat` instead, so the deprecation keeps naming the caller"
  end
end
