# frozen_string_literal: true

require "bigdecimal"

module RorMcp
  # A decimal as Django hands it to renderers: the value plus Python's str() of
  # it. Django quantizes decimal columns to their scale, so CSV prints "499.90"
  # where BigDecimal would print "499.9"; JSON renders the value as a float.
  class PyDecimal
    include Comparable

    attr_reader :value, :text

    # A column value or sum/min/max: Django quantizes to the column's decimal
    # places, rounding half-even (Python's default context).
    def self.scaled(value, scale)
      decimal = BigDecimal(BigDecimal(value.to_s).round(scale.to_i, :half_even).to_s)
      whole, fraction = decimal.to_s("F").split(".")
      new(decimal, scale.to_i.positive? ? "#{whole}.#{fraction.to_s.ljust(scale.to_i, '0')[0, scale.to_i]}" : whole)
    end

    # A value the database computed exactly (PostgreSQL / MySQL numeric): Python's str() of the Decimal.
    def self.exact(value)
      text = value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s
      new(BigDecimal(text), text)
    end

    # An average on SQLite: its float through Decimal with 15 significant digits.
    def self.significant(value, digits = 15)
      float = Float(value)
      return new(BigDecimal("0"), "0") if float.zero?

      places = [digits - 1 - Math.log10(float.abs).floor, 0].max
      text = format("%.#{places}f", float)
      new(BigDecimal(text), text)
    end

    def initialize(value, text)
      @value = value
      @text = text
    end

    # Correctly rounded, like Python's float(Decimal).
    def to_f = Float(@text)
    def to_s = @text
    def inspect = "#<PyDecimal #{@text}>"
    def hash = @value.hash

    def <=>(other)
      @value <=> (other.is_a?(PyDecimal) ? other.value : other)
    end

    # Lets numbers compare with it from either side (BigDecimal("1") == py_decimal).
    def coerce(other)
      [other, @value]
    end

    def eql?(other)
      other.is_a?(PyDecimal) && @value == other.value
    end
  end
end
