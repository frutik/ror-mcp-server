# frozen_string_literal: true

module RorMcp
  module SessionStore
    # Per-process store. Fine for development and a single process; with several
    # Puma workers or hosts a session only exists in the process that created it.
    #
    # Bounded: a session lives `expires_in` seconds from creation (the :cache
    # store's default), and past `max` sessions the oldest goes first. A client
    # whose session is gone gets 404 and initializes again (MCP transport spec).
    class Memory
      DEFAULT_MAX = 10_000

      def initialize(expires_in: Cache::DEFAULT_EXPIRES_IN, max: DEFAULT_MAX, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @expires_in = expires_in
        @max = max
        @clock = clock
        @ids = {} # id → expiry; every session gets the same lifetime, so oldest first is soonest to expire
        @mutex = Mutex.new
      end

      def create
        id = SessionStore.generate_id
        @mutex.synchronize do
          now = @clock.call
          @ids.shift while (oldest = @ids.first) && (oldest.last <= now || @ids.size >= @max)
          @ids[id] = now + @expires_in
        end
        id
      end

      def exists?(id)
        @mutex.synchronize do
          expiry = @ids[id]
          next false unless expiry
          next true if expiry > @clock.call

          @ids.delete(id)
          false
        end
      end

      def delete(id)
        @mutex.synchronize { @ids.delete(id) }
      end

      def size
        @mutex.synchronize { @ids.size }
      end
    end
  end
end
