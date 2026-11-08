# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "hecks"
require "hecks/shape_ledger"
require "hecks/rust_build/project_rust"

# Scratch worlds for the `kept?` rule: a one-bluebook domain directory with a committed hecksagon,
# an optional committed world and an optional local overlay, and the two answers asked of it.
module KeptWorlds
  BLUEBOOK = <<~RUBY
    Hecks.bluebook "Shop" do
      aggregate "Item" do
        identified_by :sku
        attribute :sku, Sku
        value_object "Sku" do
          attribute :code, String
        end
      end
    end
  RUBY

  def kept_directory = @kept_directory ||= Dir.mktmpdir("kept")

  def remove_kept_directory = FileUtils.remove_entry(kept_directory)

  def write_shop(adapter, world: nil, local: nil)
    write_kept("shop.bluebook", BLUEBOOK)
    write_kept("shop.hecksagon", %(Hecks.hecksagon "Shop" do\n  persisted_by "#{adapter}"\nend\n))
    write_kept("shop.world", world_text(world)) if world
    write_kept("shop.local.world", world_text(local)) if local
  end

  def ruby_keeps?
    registry = Hecks::ShapeLedger::Scope.committed_registry(kept_directory)
    Hecks::ShapeLedger::Kept.of?(registry, "Shop", registry.bluebooks.fetch("Shop"))
  end

  def ir_keeps?
    Hecks::RustBuild::ProjectRust::TargetIr.new(nil, "Shop", kept_directory).send(:kept?)
  end

  private

  def write_kept(file, text) = File.write(File.join(kept_directory, file), text)

  def world_text(body) = %(Hecks.world "Shop" do\n#{body}\nend\n)
end
