# frozen_string_literal: true

module RorMcp
  module Pipeline
    # A pipeline the client must fix. The message goes back to the client as an
    # isError result, so it is written for an LLM to act on.
    class QueryError < StandardError; end
  end
end
