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
