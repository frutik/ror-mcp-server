# frozen_string_literal: true

module RorMcp
  # The safety envelope every query (and every tool not declared `writes: true`)
  # runs in, whatever the pipeline semantics (PLAN §5):
  #
  #   connected_to(role:, shard:) {                   # replica / shard, when configured
  #     while_preventing_writes { transaction {        # Rails refuses write statements
  #       SET TRANSACTION READ ONLY | PRAGMA query_only # the database refuses them too
  #       statement timeout                             # PostgreSQL, MySQL
  #       … ; rolled back
  #   } } }
  #
  # It never changes results, only stops unsafe ones. Prefer a read-only
  # database role as well: these guards inspect statements, a role can't be talked out of it.
  module Envelope
    module_function

    def read_only(model = ActiveRecord::Base, role: RorMcp.configuration.read_role, shard: nil,
                  timeout: RorMcp.configuration.statement_timeout, &block)
      return yield unless active_record_connected?(model)

      connect(model, role: role, shard: shard) do
        ActiveRecord::Base.while_preventing_writes { in_rolled_back_transaction(model, timeout, &block) }
      end
    end

    def in_rolled_back_transaction(model, timeout)
      result = nil
      model.transaction(requires_new: true) do
        connection = model.connection
        restore = guard(connection, timeout)
        begin
          result = yield
        ensure
          restore&.call
        end
        raise ActiveRecord::Rollback
      end
      result
    end

    # Database-level read-only mode and timeout; returns a callable undoing
    # session-level settings.
    def guard(connection, timeout)
      milliseconds = timeout && (timeout.to_f * 1000).round
      case connection.adapter_name
      when /postg/i
        # Only the first statement of a transaction may set its access mode.
        connection.execute("SET TRANSACTION READ ONLY") if connection.open_transactions == 1
        connection.execute("SET LOCAL statement_timeout = #{milliseconds}") if milliseconds
        nil
      when /mysql|trilogy/i
        return nil unless milliseconds

        previous = connection.select_value("SELECT @@SESSION.max_execution_time")
        connection.execute("SET SESSION max_execution_time = #{milliseconds}")
        -> { connection.execute("SET SESSION max_execution_time = #{previous.to_i}") }
      when /sqlite/i
        return nil if connection.select_value("PRAGMA query_only").to_i == 1

        connection.execute("PRAGMA query_only = ON")
        -> { connection.execute("PRAGMA query_only = OFF") }
      end
    end

    def connect(model, role:, shard:, &block)
      return yield if role.nil? && shard.nil?

      owner = model.respond_to?(:connection_class_for_self) ? model.connection_class_for_self : ActiveRecord::Base
      options = { role: role, shard: shard }.compact
      owner.connected_to(**options, &block)
    end

    def active_record_connected?(model)
      model.connection_pool
      true
    rescue ActiveRecord::ConnectionNotEstablished
      false
    end
  end

  # ActiveSupport::Notifications events "query.ror_mcp" and "tool.ror_mcp",
  # plus the configuration's on_query / on_tool callbacks.
  module Instrumentation
    Event = Struct.new(:name, :server, :collection, :tool, :pipeline, :rows, :duration_ms, :error, keyword_init: true)

    module_function

    # Yields a payload hash the block can add :rows / :error to.
    def instrument(name, payload)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications.instrument(name, payload) { yield payload }
    ensure
      event = Event.new(name: name, duration_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(2),
                        **payload.slice(:server, :collection, :tool, :pipeline, :rows, :error))
      subscribers = name.start_with?("query") ? RorMcp.configuration.query_subscribers : RorMcp.configuration.tool_subscribers
      subscribers.each { |subscriber| subscriber.call(event) }
    end
  end
end
