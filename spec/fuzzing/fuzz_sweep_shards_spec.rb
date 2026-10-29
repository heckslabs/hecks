require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/tools"
require "hecks/tools/fuzz_sweep"

# `--shard I/N` and `--list-shards N`: n jobs together sweep every domain exactly once.
RSpec.describe Hecks::Tools::FuzzSweep::Shards, :aggregate_failures do
  let(:sweep) { Hecks::Tools::FuzzSweep }
  let(:root) { Hecks::Tools::ROOT }
  let(:domains) { Hecks::Corpus.fuzzable_domains(root) }
  let(:costs) { described_class.costs_from(root) }

  describe "reading the shard a sweep is asked for" do
    it "takes I/N with I from 1 to N" do
      expect(described_class.parse_shard("1/2")).to eq([1, 2])
      expect(described_class.parse_shard("2/2")).to eq([2, 2])
      expect(described_class.parse_shard("4/12")).to eq([4, 12])
    end

    %w[0/2 3/2 abc 1/0 1 1/ /2 1/2/3 -1/2 1.5/2 01/2].push("", " 1/2").each do |word|
      it "refuses #{word.inspect}, naming what is valid" do
        expect { expect(described_class.parse_shard(word)).to be_nil }
          .to output(%r{use I/N with I from 1 to N, such as 1/2}).to_stderr
      end
    end

    it "refuses a missing word" do
      expect { expect(described_class.parse_shard(nil)).to be_nil }.to output(/--shard/).to_stderr
    end
  end

  describe "the command line" do
    it "keeps no shard unless one is typed, so a sweep is today's sweep" do
      options = sweep.parse(%w[--seeds 2])

      expect(options[:shard]).to be_nil
      expect(options[:list_shards]).to be_nil
    end

    it "reads --shard as the pair it names" do
      expect(sweep.parse(%w[--shard 2/3])[:shard]).to eq([2, 3])
    end

    it "reads --list-shards as a shard count" do
      expect(sweep.parse(%w[--list-shards 3])[:list_shards]).to eq(3)
    end

    it "refuses a shard out of range, malformed, or missing its value" do
      expect { expect(sweep.parse(%w[--shard 3/2])).to be_nil }.to output(%r{use I/N}).to_stderr
      expect { expect(sweep.parse(%w[--shard 0/2])).to be_nil }.to output(%r{use I/N}).to_stderr
      expect { expect(sweep.parse(%w[--shard abc])).to be_nil }.to output(%r{use I/N}).to_stderr
      expect { expect(sweep.parse(%w[--shard])).to be_nil }.to output(%r{use I/N}).to_stderr
    end

    it "refuses a shard count of none" do
      expect { expect(sweep.parse(%w[--list-shards 0])).to be_nil }.to output(/1 or more/).to_stderr
    end

    it "refuses a shard of a named domain, which has nothing to split" do
      expect { expect(sweep.parse(%w[examples/pizzas --shard 1/2])).to be_nil }
        .to output(/no domain can be named/).to_stderr
    end

    it "refuses --shard together with --list-shards" do
      expect { expect(sweep.parse(%w[--shard 1/2 --list-shards 2])).to be_nil }
        .to output(/use one/).to_stderr
    end
  end

  describe "the split" do
    (2..4).each do |shards|
      context "with #{shards} shards" do
        let(:split) { described_class.partition(domains, shards, costs) }

        it "sweeps every domain, and no other" do
          expect(split.flatten.sort).to eq(domains.sort)
        end

        it "gives no domain to two shards" do
          expect(split.flatten.tally.select { |_, times| times > 1 }).to be_empty
          split.combination(2) { |one, other| expect(one & other).to be_empty }
        end

        it "gives every shard something to sweep" do
          expect(split).to all(satisfy { |members| !members.empty? })
        end

        it "keeps each shard's domains in discovery order" do
          expect(split).to all(satisfy { |members| members == members.sort_by { |domain| domains.index(domain) } })
        end

        it "puts a domain added to the corpus into exactly one shard" do
          added = File.join(root, "examples/zz_added_domain")
          grown = described_class.partition(domains + [added], shards, costs)

          expect(grown.count { |members| members.include?(added) }).to eq(1)
          expect(grown.flatten.sort).to eq((domains + [added]).sort)
        end

        it "puts a domain added in the middle of the corpus into exactly one shard" do
          added = File.join(root, "lib/hecks/aaa_added_domain")
          grown = described_class.partition(domains + [added], shards)

          expect(grown.count { |members| members.include?(added) }).to eq(1)
          expect(grown.flatten.sort).to eq((domains + [added]).sort)
        end

        it "is the same split however the domains are ordered or how often it is asked" do
          expect(described_class.partition(domains.shuffle(random: Random.new(7)), shards, costs).map(&:sort))
            .to eq(split.map(&:sort))
          expect(described_class.partition(domains, shards, costs)).to eq(split)
        end

        it "selects, shard by shard, exactly what the split holds" do
          (1..shards).each { |number| expect(described_class.select(domains, number, shards, costs)).to eq(split[number - 1]) }
        end
      end
    end

    it "is the whole corpus as one shard" do
      expect(described_class.partition(domains, 1, costs)).to eq([domains])
    end

    it "leaves a shard empty rather than dropping a domain when there are fewer domains than shards" do
      few = %w[/r/a /r/b]

      expect(described_class.partition(few, 4)).to eq([["/r/a"], ["/r/b"], [], []])
    end

    it "deals by cost: the dearest domain goes first and the next shard takes the next" do
      costs = { "/r/big" => 9.0, "/r/mid" => 5.0, "/r/small" => 4.0, "/r/tiny" => 1.0 }

      split = described_class.partition(costs.keys, 2, costs)

      expect(split).to eq([["/r/big", "/r/tiny"], ["/r/mid", "/r/small"]])
    end

    it "orders a shard's domains dearest first, equal costs in path order" do
      costs = { "/r/a" => 1.0, "/r/b" => 5.0, "/r/c" => 5.0, "/r/d" => 9.0 }

      expect(described_class.dearest_first(%w[/r/a /r/b /r/c /r/d], costs)).to eq(%w[/r/d /r/b /r/c /r/a])
    end

    it "costs a domain the table does not name at the table's median" do
      costs = { "/r/a" => 1.0, "/r/b" => 3.0, "/r/c" => 100.0 }

      expect(described_class.prices(%w[/r/a /r/new], costs)).to eq([1.0, 3.0])
    end

    it "costs every domain alike when there is no table" do
      expect(described_class.prices(%w[/r/a /r/b], {})).to eq([1.0, 1.0])
      expect(described_class.partition(%w[/r/a /r/b /r/c /r/d], 2)).to eq([%w[/r/a /r/c], %w[/r/b /r/d]])
    end
  end

  describe "the committed cost table" do
    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    def write_table(text)
      path = File.join(@dir, described_class::COST_TABLE)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end

    it "is read as seconds by absolute domain directory" do
      write_table("# a comment\nexamples/pizzas:12.5\n\nlib/hecks/site:3\n")

      expect(described_class.costs_from(@dir))
        .to eq(File.join(@dir, "examples/pizzas") => 12.5, File.join(@dir, "lib/hecks/site") => 3.0)
    end

    it "is empty when the checkout has none" do
      expect(described_class.costs_from(@dir)).to eq({})
    end

    it "prices the committed table's domains" do
      expect(costs).not_to be_empty
      expect(costs.values).to all(be_positive)
    end
  end

  describe "the listing, which proves coverage without a sweep" do
    def relative(paths) = paths.map { |path| path.delete_prefix("#{root}/") }

    def assignment(split, shards)
      split.each_with_index.to_h { |members, index| ["#{index + 1}/#{shards}", relative(members)] }
    end

    (2..4).each do |shards|
      it "names every domain once, under the shard that sweeps it, for #{shards} shards" do
        rows = described_class.listing(domains, shards, costs, root).map { |line| line.split("\t") }

        expect(rows.map(&:last).sort).to eq(relative(domains).sort)
        expect(rows.map(&:first).uniq).to eq((1..shards).map { |number| "#{number}/#{shards}" })
        expect(rows.group_by(&:first).transform_values { |group| group.map(&:last) })
          .to eq(assignment(described_class.partition(domains, shards, costs), shards))
      end
    end

    it "carries each domain's cost as a number" do
      row = described_class.listing(%w[/r/a], 1, { "/r/a" => 2.25 }, "/r").first.split("\t")

      expect(row).to eq(["1/1", "2.3", "a"])
    end

    it "refuses a split that is not a partition" do
      allow(described_class).to receive(:partition).and_return([%w[/r/a], %w[/r/a]])

      expect { described_class.listing(%w[/r/a /r/b], 2, {}, "/r") }.to raise_error(/not a partition/)
    end
  end

  describe "main" do
    it "prints the listing for --list-shards and sweeps nothing" do
      allow(sweep).to receive(:sweep)

      expect { expect(sweep.main(%w[--list-shards 2], root: root)).to eq(0) }
        .to output(%r{^1/2\t\d+\.\d\t\S+$}).to_stdout
      expect(sweep).not_to have_received(:sweep)
    end

    # The domains `main` hands the sweep for these words, with the sweep itself stubbed clean.
    def swept_by(words)
      swept = nil
      allow(sweep).to receive(:adapter_ready?).and_return(true)
      allow(sweep).to receive(:sweep) { |chosen, *| (swept = chosen) && true }
      expect { sweep.main(words, root: root) }.to output(/CLEAN/).to_stdout
      swept
    end

    it "sweeps only the domains of the shard it is asked for" do
      expect(swept_by(%w[--shard 2/3]).sort).to eq(described_class.select(domains, 2, 3, costs).sort)
    end

    it "starts the dearest domain of its shard first" do
      swept = swept_by(%w[--shard 2/3])

      expect(swept).to eq(described_class.dearest_first(swept, costs))
      expect(described_class.prices(swept, costs).first).to eq(described_class.prices(swept, costs).max)
    end

    it "sweeps every domain when no shard is asked for" do
      expect(swept_by([])).to eq(domains)
    end

    it "refuses a shard out of range and sweeps nothing" do
      allow(sweep).to receive(:sweep)

      expect { expect(sweep.main(%w[--shard 3/2], root: root)).to eq(1) }.to output(%r{use I/N}).to_stderr
      expect(sweep).not_to have_received(:sweep)
    end

    it "exits non-zero when a domain of the shard finds something" do
      allow(sweep).to receive_messages(adapter_ready?: true, sweep: false)

      expect { expect(sweep.main(%w[--shard 1/2], root: root)).to eq(1) }.to output(/FUZZ FOUND SOMETHING/).to_stdout
    end
  end
end
