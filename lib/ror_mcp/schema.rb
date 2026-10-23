# frozen_string_literal: true

module RorMcp
  # The MongoDB-style $jsonSchema of a collection, built exactly as
  # django-mcp-server's generate_json_schema builds it (same keys, same key
  # order), from Rails metadata: column types, belongs_to reflections, enums,
  # and descriptions from `describe` or column comments.
  module Schema
    # One model field: a column, or a belongs_to association named after its
    # foreign-key column (Django's ForeignKey `customer` over column `customer_id`).
    Field = Struct.new(:name, :column, :reflection, :primary_key, keyword_init: true) do
      def reference? = !reflection.nil?
      def attname = column.name
      def text? = !reference? && %i[string text].include?(column.type)
    end

    PRIMARY_KEY_DESCRIPTION = "Primary unique identifier for this model"

    # Django field class → bsonType, by Rails column type. Every integer is "int":
    # Django checks IntegerField before BigIntegerField/BigAutoField.
    BSON_TYPES = {
      integer: "int", float: "double", decimal: "double", boolean: "bool",
      datetime: "date", timestamp: "date", date: "date", time: "string",
      json: "object", jsonb: "object", string: "string", text: "string",
    }.freeze

    module_function

    # Every concrete field of a model, in column order.
    def model_fields(model)
      references = model.reflect_on_all_associations(:belongs_to).reject(&:polymorphic?)
                        .to_h { |reflection| [reflection.foreign_key.to_s, reflection] }
      model.columns.map do |column|
        reflection = references[column.name]
        Field.new(name: reflection ? reflection.name.to_s : column.name, column: column,
                  reflection: reflection, primary_key: column.name == model.primary_key)
      end
    end

    # The fields a collection publishes: `fields`, minus `exclude_fields`, minus
    # references to models not published on the same server. As in
    # django-mcp-server, "published" means the exact class (PLAN §1A.7).
    def fields_of(collection, published_models = published_models_for(collection))
      listed = collection.fields
      model_fields(collection.model).select do |field|
        next false unless listed == :all || listed.include?(field.name)
        next false if collection.exclude_fields.include?(field.name)

        !field.reference? || published_models.include?(field.reflection.klass)
      end
    end

    def published_models_for(collection)
      RorMcp.registry.collections_for(collection.server_key).values.map(&:model)
    end

    # django-mcp-server's get_text_search_fields.
    def text_search_fields(collection)
      return collection.search_fields if collection.search_fields

      listed = collection.fields
      model_fields(collection.model).select { |f| f.text? && (listed == :all || listed.include?(f.name)) }.map(&:name)
    end

    def json_schema(collection, published_models = published_models_for(collection))
      properties = {}
      required = []
      fields_of(collection, published_models).each do |field|
        properties[field.name] = property(collection, field)
        required << field.name if required?(field)
      end
      collection.computed_fields.each_value { |computed| properties[computed.name] = computed_property(computed) }

      body = { "bsonType" => "object", "properties" => properties }
      body["required"] = required unless required.empty?
      { "description" => model_description(collection), "$jsonSchema" => body }
    end

    def property(collection, field)
      prop = {}
      prop["description"] = PRIMARY_KEY_DESCRIPTION if field.primary_key
      help = collection.field_descriptions[field.name] || field.column.comment

      if field.reference?
        target = field.reflection.klass.name.demodulize
        prop["bsonType"] = "objectId"
        prop["description"] = "Reference to #{target}"
        prop["description"] += ": #{help}" if help
        prop["ref"] = target
        return prop
      end

      prop["bsonType"] = BSON_TYPES.fetch(field.column.type, "string")
      prop["description"] = help if help
      choices = choices(collection, field)
      if choices
        prop["enum"] = choices.keys
        listing = choices.map { |value, label| "#{PythonRepr.dump(value)} = #{label}" }.join(", ")
        prop["description"] = prop.key?("description") ? "#{prop['description']} Choices: #{listing}" : "Choices: #{listing}"
      end
      prop
    end

    def computed_property(computed)
      note = "Computed value, not a stored column or reference."
      { "bsonType" => BSON_TYPES.fetch(computed.type, "string"),
        "description" => computed.doc ? "#{computed.doc}. #{note}" : note }
    end

    # { stored value => label } for a Rails enum, or nil.
    def choices(collection, field)
      mapping = collection.model.defined_enums[field.attname]
      return nil unless mapping

      labels = collection.all_choice_labels.fetch(field.name, {})
      mapping.to_h { |key, value| [value, labels.fetch(value.to_s) { key.to_s.humanize }] }
    end

    # Django: null=False and blank=False. Auto-increment keys are blank; a string
    # column defaulting to "" stands in for blank=True.
    def required?(field)
      column = field.column
      return false if column.null
      return false if field.primary_key && column.type == :integer
      return false if field.text? && column.default == ""

      true
    end

    # The collection's description, else Django's auto docstring "Model(field, ...)".
    def model_description(collection)
      collection.description&.strip ||
        "#{collection.model.name.demodulize}(#{model_fields(collection.model).map(&:name).join(', ')})"
    end
  end
end
