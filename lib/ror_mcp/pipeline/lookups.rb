# frozen_string_literal: true

module RorMcp
  module Pipeline
    # $lookup as django-mcp-server implements it: no join by itself. Each stage
    # is validated and records an alias, `as` → `localField.replace("_id", "")`;
    # later "alias.field" references become "prefix__field" paths, and the join
    # happens when a path is used. All $lookup stages are read first, wherever
    # they sit in the pipeline (PLAN §1A.6).
    class Lookups
      def initialize(fields, published_models)
        @fields = fields
        # Django compares `from` with model names (lowercase class names), not collection names.
        @allowed = published_models.map { |model| model.name.demodulize.downcase }
        @aliases = {}
      end

      def register(lookup)
        raise QueryError, "$lookup must be an object" unless lookup.is_a?(Hash)

        from, local, foreign, as = %w[from localField foreignField as].map do |key|
          lookup.fetch(key) { raise QueryError, "$lookup is missing '#{key}'" }
        end
        unless @allowed.include?(from.to_s.downcase)
          raise QueryError, "Invalid lookup from collection '#{from}'  : please reveiw schemas."
        end

        local_path = translate(local.to_s)
        validate(local, local_path, foreign)
        # Quirk kept on purpose: every "_id" is removed, so "billing_identity" becomes "billingentity".
        @aliases[as.to_s] = local_path.gsub("_id", "")
      end

      # django-mcp-server's _translate_field.
      def translate(name)
        name = name.to_s
        return "pk" if name == "_id"
        return name unless name.include?(".")

        alias_name, rest = name.split(".", 2)
        prefix = @aliases.fetch(alias_name) do
          raise QueryError, "Unknown lookup alias '#{alias_name}', ensure it appears in the 'as' field of a previous $lookup"
        end
        "#{prefix}__#{rest}"
      end

      private

      # django-mcp-server's _validate_lookup: localField must be a many-to-one
      # field of the model it reaches, foreignField that model's key.
      def validate(local, local_path, foreign)
        model = base_model_of(local_path)
        field = @fields.find(model, local_path.split("__").last)
        model_name = model.name.demodulize.downcase
        unless field
          raise QueryError, "Invalid localField '#{local}' : please review supported pipeline syntax and  schemas for #{model_name}.'."
        end
        unless field.reference?
          raise QueryError, "Invalid localField '#{local}' : is not a reference, please review supported pipeline syntax and  schemas for #{model_name}."
        end

        target_key = @fields.primary_key(field.reflection.klass).attname
        return if [target_key, "_id", "pk"].include?(foreign.to_s)

        raise QueryError, "Invalid foreignField '#{foreign}': please review supported pipeline syntax and  schemas for #{model_name}."
      end

      # Walks "a__b__c" through relations; stops at the first non-relation, like _resolve_model_from_path.
      def base_model_of(path)
        model = @fields.model
        path.split("__")[0..-2].each do |part|
          field = @fields.find(model, part)
          raise QueryError, "Invalid field path '#{path}' at '#{part}' in model '#{model.name.demodulize}'." unless field
          break unless field.reference?

          model = field.reflection.klass
        end
        model
      end
    end
  end
end

module RorMcp
  module Pipeline
    class Lookups
      # Django field lookups beyond the base operators, compiled to the SQL
      # Django generates (LIKE with escaping, year as a range, date-part
      # extraction). On SQLite, LIKE is case-insensitive for ASCII either way,
      # as it is for Django.
      LIKE_PATTERNS = {
        "contains" => "%%%s%%", "icontains" => "%%%s%%", "startswith" => "%s%%", "istartswith" => "%s%%",
        "endswith" => "%%%s", "iendswith" => "%%%s", "iexact" => "%s",
      }.freeze
      DATE_PARTS = %w[month day hour minute second week_day quarter].freeze

      def self.extended(kind, attribute, value, resolved, connection, field)
        sqlite = connection.adapter_name.match?(/sqlite/i)
        case kind
        when *LIKE_PATTERNS.keys
          pattern = format(LIKE_PATTERNS[kind], value.to_s.gsub(/[\\%_]/) { |c| "\\#{c}" })
          attribute.matches(pattern, "\\", !kind.start_with?("i"))
        when "regex", "iregex"
          pattern = kind == "iregex" ? "(?i)#{value}" : value.to_s
          Arel::Nodes::InfixOperation.new(sqlite ? "REGEXP" : (kind == "iregex" ? "~*" : "~"), attribute, Arel::Nodes.build_quoted(pattern))
        when "range"
          raise QueryError, "$range takes [low, high]" unless value.is_a?(Array) && value.size == 2

          attribute.between(value[0]..value[1])
        when "year"
          # Django turns an exact year into a range, so it can use indexes.
          year = Integer(value)
          date = %i[date].include?(resolved.field.column&.type)
          low, high = date ? [Date.new(year, 1, 1), Date.new(year + 1, 1, 1)] : [Time.utc(year), Time.utc(year + 1)]
          Arel::Nodes::Grouping.new(attribute.gteq(low).and(attribute.lt(high)))
        when "date"
          date = sqlite ? Arel::Nodes::NamedFunction.new("date", [attribute]) : Arel::Nodes::NamedFunction.new("CAST", [attribute.as(Arel.sql("date"))])
          date.eq(Arel::Nodes.build_quoted(value.to_s))
        when *DATE_PARTS
          date_part(kind, attribute, connection).eq(Integer(value))
        else
          raise QueryError, "Unsupported lookup '#{kind}' for field '#{field}'"
        end
      rescue ArgumentError, TypeError => e
        raise QueryError, "Invalid value for $#{kind} on '#{field}': #{e.message}"
      end

      SQLITE_FORMATS = { "month" => "%m", "day" => "%d", "hour" => "%H", "minute" => "%M", "second" => "%S", "week_day" => "%w" }.freeze

      def self.date_part(kind, attribute, connection)
        column = connection.visitor.accept(attribute, Arel::Collectors::SQLString.new).value
        if connection.adapter_name.match?(/sqlite/i)
          return Arel.sql("((CAST(strftime('%m', #{column}) AS INTEGER) + 2) / 3)") if kind == "quarter"

          part = "CAST(strftime('#{SQLITE_FORMATS.fetch(kind)}', #{column}) AS INTEGER)"
          # Django's week_day: 1 = Sunday … 7 = Saturday; strftime('%w') is 0 = Sunday.
          return Arel.sql(kind == "week_day" ? "(#{part} + 1)" : part)
        end

        return Arel.sql("(EXTRACT(DOW FROM #{column}) + 1)") if kind == "week_day"

        Arel.sql("EXTRACT(#{kind.upcase} FROM #{column})")
      end
    end
  end
end
