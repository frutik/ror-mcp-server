# frozen_string_literal: true

module RorMcp
  # Publishes an ActiveRecord model as a queryable collection (django-mcp-server's
  # ModelQueryToolset). See README "Collections reference".
  #
  #   class OrderCollection < RorMcp::Collection
  #     model  Order
  #     fields :id, :number, :status, :customer
  #     def scope(context) = Order.where(account: context[:account])
  #   end
  class Collection
    OUTPUT_FORMATS = %i[json csv jsonl].freeze

    # A value computed in SQL (`computed :line_count, :integer, sql: "…"`). "{table}"
    # in the SQL stands for the collection's table, or its alias when reached
    # through a $lookup.
    Computed = Struct.new(:name, :type, :sql, :doc, keyword_init: true) do
      def attname = name
      def reference? = false
      def primary_key = false
      def text? = false

      def expression(table, connection)
        Arel.sql("(#{sql.gsub('{table}', connection.quote_table_name(table.name))})")
      end

      def database_type
        ActiveRecord::Type.lookup(type)
      end
    end

    class << self
      def inherited(subclass)
        super
        RorMcp.registry.track(subclass)
      end

      # --- DSL -----------------------------------------------------------------

      def server(key = nil)
        key.nil? ? server_key : (@server = key.to_sym)
      end

      def model(klass = nil)
        klass.nil? ? setting(:model) : (@model = klass)
      end

      # Name clients use. Default: the model's singular route key ("line_item");
      # set "lineitem" to match django-mcp-server's lowercase model name.
      def collection_name(name = nil)
        return (@collection_name = name.to_s) unless name.nil?

        setting(:collection_name) || model&.model_name&.singular
      end

      # Published fields: column names, belongs_to association names, or :all. Required.
      def fields(*names)
        return setting(:fields) if names.empty?

        @fields = names == [:all] ? :all : names.flatten.map(&:to_s)
      end

      def exclude_fields(*names)
        names.empty? ? (setting(:exclude_fields) || []) : (@exclude_fields = names.flatten.map(&:to_s))
      end

      # Fields for $text / $search. Default: string and text columns within `fields`.
      def search_fields(*names)
        names.empty? ? setting(:search_fields) : (@search_fields = names.flatten.map(&:to_s))
      end

      # Extra $match operators clients may use, e.g. :icontains (django-mcp-server's extra_filters).
      def extra_filters(*operators)
        operators.empty? ? (setting(:extra_filters) || []) : (@extra_filters = operators.flatten.map(&:to_s))
      end

      # Text appended to the collection's schema in the tool description (extra_instructions).
      def instructions(text = nil)
        text.nil? ? setting(:instructions) : (@instructions = text.to_s)
      end

      # The schema's top-level "description" (Django uses the model's docstring).
      def description(text = nil)
        text.nil? ? setting(:description) : (@description = text.to_s)
      end

      # A field's description (Django's help_text). Column comments are used when absent.
      def describe(field, text)
        @field_descriptions = field_descriptions.merge(field.to_s => text.to_s)
      end

      def field_descriptions
        setting(:field_descriptions) || {}
      end

      # Labels for an enum's values (Django's choices). Default label: the enum key, humanized.
      def choice_labels(field, labels)
        @choice_labels = all_choice_labels.merge(field.to_s => labels.transform_keys(&:to_s))
      end

      def all_choice_labels
        setting(:choice_labels) || {}
      end

      # A field computed in SQL: published in the schema and usable in every stage,
      # also from other collections through $lookup.
      def computed(name, type, sql:, doc: nil)
        @computed = computed_fields.merge(name.to_s => Computed.new(name: name.to_s, type: type.to_sym, sql: sql, doc: doc))
      end

      def computed_fields
        setting(:computed) || {}
      end

      def output_format(format = nil)
        format.nil? ? (setting(:output_format) || :json) : (@output_format = format.to_sym)
      end

      # Attach results as an embedded resource instead of returning them as text.
      def output_as_resource(value = nil)
        value.nil? ? (setting(:output_as_resource) || false) : (@output_as_resource = value)
      end

      # A shared base class that is never published itself.
      def abstract!
        @abstract = true
      end

      # --- introspection -------------------------------------------------------

      def abstract?
        @abstract == true
      end

      def published?
        !abstract? && !model.nil? && !name.nil?
      end

      def server_key
        setting(:server) || :default
      end

      def schema_fields
        Schema.fields_of(self)
      end

      # Checks that need no database, so they can run at boot (db:prepare,
      # assets:precompile and friends boot the app before the schema exists).
      def validate!
        if fields.nil?
          raise ConfigurationError, "#{name}: `fields` is required. List the published fields, or use `fields :all` " \
                                    "(see README \"Description size\")."
        end
        unless OUTPUT_FORMATS.include?(output_format)
          raise ConfigurationError, "#{name}: output_format #{output_format.inspect} is unknown " \
                                    "(available: #{OUTPUT_FORMATS.join(', ')})."
        end
        true
      end

      # Checks against the model's columns; run when a server builds its tools.
      def validate_columns!
        known = Schema.model_fields(model).map(&:name)
        [[:fields, fields == :all ? [] : fields], [:exclude_fields, exclude_fields],
         [:search_fields, search_fields || []]].each do |option, names|
          unknown = names - known
          next if unknown.empty?

          raise ConfigurationError, "#{name}: #{option} #{unknown.join(', ')} not found on #{model.name}. " \
                                    "Available: #{known.join(', ')}."
        end
        true
      end

      private

      # A DSL value set on this class or inherited from a Collection superclass.
      def setting(name)
        ivar = :"@#{name}"
        return instance_variable_get(ivar) if instance_variable_defined?(ivar)

        superclass.send(:setting, name) if superclass < Collection
      end
    end

    attr_reader :context

    def initialize(context = nil)
      @context = context
    end

    # The relation queries start from (django-mcp-server's get_queryset).
    def scope(_context)
      self.class.model.all
    end
  end
end
