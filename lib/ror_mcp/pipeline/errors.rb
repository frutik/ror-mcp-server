# frozen_string_literal: true

module RorMcp
  module Pipeline
    # A pipeline the client must fix. The message goes back to the client as an
    # isError result, so it is written for an LLM to act on.
    class QueryError < StandardError; end

    # A stage or operator the port supports in a later milestone.
    class NotYetSupported < QueryError
      def initialize(feature, milestone)
        super("#{feature} is not supported yet (planned for milestone #{milestone}).")
      end
    end
  end
end
