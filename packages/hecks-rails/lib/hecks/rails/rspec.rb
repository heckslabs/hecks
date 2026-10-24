require "cgi"
require "rspec/expectations"

module Hecks
  module Rails
    # RSpec matchers for a Rails app driving Hecks: `require "hecks/rails/rspec"` in a spec helper.
    module RSpec
      # Holds whether a block raised a refusal, or a response answered one, with the words expected.
      #
      #   expect { account.freeze_account! }.to be_refused_with("FreezeAccount refused")
      #   expect(response).to be_refused_with("FreezeAccount refused")
      class BeRefusedWith
        # @param words [String, Regexp] the refusal's wording, or a part of it
        def initialize(words)
          @words = words
        end

        # Answers whether the block raised a refusal, or the response is a 422, carrying the words.
        #
        # @param actual [Proc, #status] the block under test, or a response
        # @return [Boolean] true when a refusal with the words was raised or answered
        def matches?(actual)
          @said = actual.is_a?(Proc) ? raised_words(actual) : answered_words(actual)
          !@said.nil? && worded?(@said)
        end

        # Lets the matcher take a block.
        #
        # @return [Boolean] always true
        def supports_block_expectations? = true

        # Explains a failed match.
        #
        # @return [String] what was expected and what was said instead
        def failure_message
          return "expected a refusal with #{@words.inspect}, but nothing was refused" if @said.nil?

          "expected a refusal with #{@words.inspect}, but it said: #{@said}"
        end

        # Explains a failed negated match.
        #
        # @return [String] the refusal that was not expected
        def failure_message_when_negated = "expected no refusal with #{@words.inspect}, but it said: #{@said}"

        private

        def raised_words(block)
          block.call
          nil
        rescue Hecks::Refused => e
          e.message
        end

        def answered_words(response) = response.status == 422 ? CGI.unescapeHTML(response.body.to_s) : nil

        def worded?(said) = @words.is_a?(Regexp) ? @words.match?(said) : said.include?(@words)
      end

      # Builds the matcher.
      #
      # @param words [String, Regexp] the refusal's wording, or a part of it
      # @return [Rails::RSpec::BeRefusedWith] the matcher
      def be_refused_with(words) = BeRefusedWith.new(words)
    end
  end
end

RSpec.configure { |config| config.include Hecks::Rails::RSpec } if defined?(RSpec.configure)
