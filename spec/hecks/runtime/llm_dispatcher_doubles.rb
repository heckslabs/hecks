# spec/hecks/runtime/llm_dispatcher_doubles.rb
#
# Test doubles for the LlmDispatcher spec. Pulled out of the spec file
# to keep both bodies under the 200-LoC code-only limit. Each double
# implements only the slice of the port the dispatcher actually calls,
# so the duck-type contract stays explicit.
#
#   require_relative "llm_dispatcher_doubles"
#   logger   = LlmDispatcherDoubles::FakeLogger.new
#   spend    = LlmDispatcherDoubles::FakeSpend.new(over_budget: true)
#   breaker  = LlmDispatcherDoubles::FakeBreaker.new(open: false)
#   provider = LlmDispatcherDoubles::FakeProvider.new(response_text: "ok")
#
module LlmDispatcherDoubles
  # Captures dispatched events (#<<) so specs can assert ordering + content.
  class FakeLogger
    def initialize; @events = []; end
    def <<(payload); @events << payload; self; end
    def events = @events
    def event_names = @events.map { |e| e[:event] }
  end

  # In-memory spend port. Duck type the dispatcher expects:
  # over_budget?(period:), override_active?(period:, now:), record_call(**attrs).
  class FakeSpend
    attr_reader :recorded_calls
    def initialize(over_budget: false, override: false, raise_on_record: nil)
      @over_budget = over_budget
      @override = override
      @raise_on_record = raise_on_record
      @recorded_calls = []
    end
    def over_budget?(period:)
      raise @over_budget if @over_budget.is_a?(Exception)
      @over_budget
    end
    def override_active?(period:, now:); @override; end
    def record_call(**attrs)
      raise @raise_on_record if @raise_on_record
      @recorded_calls << attrs
      true
    end
  end

  # In-memory circuit-breaker port. Duck type: open?, record_success,
  # record_failure — all keyed by :kind.
  class FakeBreaker
    attr_reader :successes, :failures
    def initialize(open: false)
      @open = open
      @successes = []
      @failures = []
    end
    def open?(kind:); @open; end
    def record_success(kind:); @successes << kind; true; end
    def record_failure(kind:); @failures << kind; true; end
  end

  # Provider stub — implements the LlmProviders contract :
  #   invoke(prompt:, model:, max_tokens:, stream: false) -> Result
  # Provider Result has response_text, tokens_in, tokens_out, model_used, raw.
  class FakeProvider
    ProviderResult = Struct.new(
      :response_text, :tokens_in, :tokens_out, :model_used, :raw,
      keyword_init: true
    )
    attr_reader :calls
    def initialize(response_text: "ok", tokens_in: 1, tokens_out: 1,
                   model_used: nil, raw: nil, raises: nil)
      @response_text = response_text
      @tokens_in = tokens_in
      @tokens_out = tokens_out
      @model_used = model_used
      @raw = raw
      @raises = raises
      @calls = []
    end
    def invoke(prompt:, model:, max_tokens:, stream: false)
      @calls << { prompt: prompt, model: model, max_tokens: max_tokens, stream: stream }
      raise @raises if @raises
      ProviderResult.new(
        response_text: @response_text, tokens_in: @tokens_in,
        tokens_out: @tokens_out, model_used: @model_used || model, raw: @raw
      )
    end
  end
end
