# frozen_string_literal: true

module RorMcp
  module SessionStore
    # Store backed by an ActiveSupport cache, Rails.cache by default. Shared across
    # processes only when the cache is (Redis, Memcached, Solid Cache).
    class Cache
      # Django's default session lifetime (SESSION_COOKIE_AGE).
      DEFAULT_EXPIRES_IN = 14 * 24 * 60 * 60

      def initialize(cache: nil, expires_in: DEFAULT_EXPIRES_IN, namespace: "ror_mcp:session")
        @cache = cache
        @expires_in = expires_in
        @namespace = namespace
      end

      def create
        id = SessionStore.generate_id
        cache.write(key(id), true, expires_in: @expires_in)
        id
      end

      def exists?(id)
        cache.exist?(key(id))
      end

      def delete(id)
        cache.delete(key(id))
      end

      private

      def cache
        @cache ||= Rails.cache
      end

      def key(id)
        "#{@namespace}:#{id}"
      end
    end
  end
end
