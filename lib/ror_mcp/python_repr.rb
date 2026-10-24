# frozen_string_literal: true

module RorMcp
  # Python's repr() of dicts, lists, strings and numbers. django-mcp-server puts
  # repr(schema) inside the ```json fence of the query tool description, so the
  # port has to print the same text (PLAN §1A.7).
  module PythonRepr
    ESCAPES = { "\\" => "\\\\", "\n" => "\\n", "\r" => "\\r", "\t" => "\\t" }.freeze

    module_function

    def dump(value)
      case value
      when Hash then "{#{value.map { |k, v| "#{dump(k)}: #{dump(v)}" }.join(', ')}}"
      when Array then "[#{value.map { |v| dump(v) }.join(', ')}]"
      when String, Symbol then string(value.to_s)
      when true then "True"
      when false then "False"
      when nil then "None"
      when Float then PythonFloat.repr(value)
      when Integer then value.to_s
      else raise ArgumentError, "no Python repr for #{value.class}"
      end
    end

    # Single quotes unless the text holds a ' and no ", like CPython.
    def string(text)
      quote = text.include?("'") && !text.include?('"') ? '"' : "'"
      body = text.each_char.map do |char|
        if ESCAPES.key?(char) then ESCAPES[char]
        elsif char == quote then "\\#{quote}"
        elsif char.ord < 0x20 || char.ord == 0x7f then format("\\x%02x", char.ord)
        else char
        end
      end
      "#{quote}#{body.join}#{quote}"
    end
  end

  # Python's float repr: Ruby prints 1e16 as "1.0e+16", Python as "1e+16".
  module PythonFloat
    module_function

    def repr(value)
      return "inf" if value == Float::INFINITY
      return "-inf" if value == -Float::INFINITY
      return "nan" if value.nan?

      value.to_s.sub(".0e", "e")
    end
  end
end
