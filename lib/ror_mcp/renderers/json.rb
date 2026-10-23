# frozen_string_literal: true

require "bigdecimal"
require "date"

module RorMcp
  module Renderers
    # Output of DRF's JSONRenderer as django-mcp-server uses it: compact
    # separators, UTF-8 (no \u escapes for non-ASCII),  /  escaped, and
    # DRF's JSONEncoder for values (decimals as floats, ISO 8601 datetimes with
    # "Z" for UTC and microseconds only when non-zero).
    module Json
      FORMAT = "json"
      MEDIA_TYPE = "application/json"

      ESCAPES = { '"' => '\\"', "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t",
                  "\b" => "\\b", "\f" => "\\f", " " => "\\u2028", " " => "\\u2029" }.freeze

      module_function

      def render(value)
        encode(value)
      end

      def encode(value)
        case value
        when Hash then "{#{value.map { |k, v| "#{string(k.to_s)}:#{encode(v)}" }.join(',')}}"
        when Array then "[#{value.map { |v| encode(v) }.join(',')}]"
        when String then string(value)
        when Symbol then string(value.to_s)
        when nil then "null"
        when true then "true"
        when false then "false"
        when Integer then value.to_s
        when BigDecimal then float(value.to_f)
        when Float then float(value)
        when Time, DateTime then string(datetime(value))
        when Date then string(value.iso8601)
        else
          raise TypeError, "Object of type #{value.class} is not JSON serializable" unless value.respond_to?(:as_json)

          encode(value.as_json)
        end
      end

      def string(text)
        body = text.each_char.map do |char|
          ESCAPES.fetch(char) { char.ord < 0x20 ? format("\\u%04x", char.ord) : char }
        end
        "\"#{body.join}\""
      end

      def float(value)
        # Python's json writes NaN/Infinity for non-finite floats (DRF allows them).
        return "NaN" if value.nan?
        return value.positive? ? "Infinity" : "-Infinity" if value.infinite?

        PythonFloat.repr(value)
      end

      # datetime.isoformat(): microseconds only when non-zero; DRF turns +00:00 into Z.
      # Django (USE_TZ) reads datetimes back in UTC whatever the app's time zone.
      def datetime(value)
        time = (value.is_a?(DateTime) ? value.to_time : value).utc
        text = time.usec.zero? ? time.iso8601 : time.iso8601(6)
        text.sub(/(\+00:00|Z)\z/, "Z")
      end
    end
  end
end
