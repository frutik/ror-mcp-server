# frozen_string_literal: true

module RorMcp
  module SessionStore
    # Per-process store. Fine for development and a single process; with several
    # Puma workers or hosts a session only exists in the process that created it.
    class Memory
      def initialize
        @ids = {}
        @mutex = Mutex.new
      end

      def create
        id = SessionStore.generate_id
        @mutex.synchronize { @ids[id] = true }
        id
      end

      def exists?(id)
        @mutex.synchronize { @ids.key?(id) }
      end

      def delete(id)
        @mutex.synchronize { @ids.delete(id) }
      end
    end
  end
end
