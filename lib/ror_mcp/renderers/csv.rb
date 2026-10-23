# frozen_string_literal: true

require "csv"

module RorMcp
  module Renderers
    # Output of djangorestframework-csv's CSVRenderer as django-mcp-server uses
    # it: nested values flattened to dotted columns, header sorted, Python's
    # csv dialect (\r\n, minimal quoting) and Python's str() for values.
    module Csv
      FORMAT = "csv"
      MEDIA_TYPE = "text/csv"

      module_function

      def render(rows)
        rows = Array(rows).map { |row| flatten(row) }
        header = rows.flat_map(&:keys).uniq.sort
        lines = [header] + rows.map { |row| header.map { |key| row[key] } }
        lines.map { |line| CSV.generate_line(line.map { |v| cell(v) }, row_sep: "\r\n") }.join
      end

      # {"a" => {"b" => 1}, "c" => [2]} → {"a.b" => 1, "c.0" => 2}
      def flatten(value, prefix = nil, out = {})
        case value
        when Hash then value.each { |k, v| flatten(v, prefix ? "#{prefix}.#{k}" : k.to_s, out) }
        when Array then value.each_with_index { |v, i| flatten(v, prefix ? "#{prefix}.#{i}" : i.to_s, out) }
        else out[prefix] = value
        end
        out
      end

      # Python's str(); empty cells unquoted (Ruby would quote "").
      def cell(value)
        text =
          case value
          when nil then nil
          when true then "True"
          when false then "False"
          when Float then PythonFloat.repr(value)
          when BigDecimal then value.to_s("F")
          when Time, DateTime then datetime(value)
          when Date then value.iso8601
          else value.to_s
          end
        text.nil? || text.empty? ? nil : text
      end

      # str(datetime): "2024-11-26 12:23:00+00:00", microseconds only when non-zero.
      def datetime(value)
        time = (value.is_a?(DateTime) ? value.to_time : value).utc
        base = time.strftime("%Y-%m-%d %H:%M:%S")
        base += format(".%06d", time.usec) unless time.usec.zero?
        "#{base}+00:00"
      end
    end

    # One JSON object per line (no Django counterpart).
    module Jsonl
      FORMAT = "jsonl"
      MEDIA_TYPE = "application/jsonl"

      def self.render(rows)
        Array(rows).map { |row| "#{Json.render(row)}\n" }.join
      end
    end

    BY_FORMAT = { json: Json, csv: Csv, jsonl: Jsonl }.freeze

    def self.for(format)
      BY_FORMAT.fetch(format.to_sym)
    end
  end
end
