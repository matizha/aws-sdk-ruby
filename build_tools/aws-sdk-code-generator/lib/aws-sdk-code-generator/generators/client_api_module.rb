module AwsSdkCodeGenerator
  module Generators
    class ClientApiModule < Dsl::Module

      include Helper

      SKIP_TRAITS = Set.new(%w(shape deprecated location locationName documentation))

      SHAPE_CLASSES = {
        'blob' => 'BlobShape',
        'byte' => 'IntegerShape',
        'boolean' => 'BooleanShape',
        'character' => 'StringShape',
        'double' => 'FloatShape',
        'float' => 'FloatShape',
        'integer' => 'IntegerShape',
        'list' => 'ListShape',
        'long' => 'IntegerShape',
        'map' => 'MapShape',
        'string' => 'StringShape',
        'structure' => 'StructureShape',
        'timestamp' => 'TimestampShape',
      }

      SHAPE_KEYS = {
        # keep
        'flattened' => true,
        'timestampFormat' => true, # glacier api customization
        'xmlNamespace' => true,
        # ignore
        'box' => false,
        'fault' => false,
        'error' => false,
        'deprecated' => false,
        'type' => false,
        'documentation' => false,
        'members' => false,
        'member' => false,
        'key' => false,
        'locationName'  => false,
        'value' => false,
        'required' => false,
        'streaming'  => false,
        'enum' => false,
        'exception' => false,
        'payload' => false,
        'pattern' => false,
        'sensitive' => false,
        'min' => false,
        'max' => false,
        'wrapper' => false,
        'xmlOrder' => false,
      }

      METADATA_KEYS = {
        # keep
        'endpointPrefix' => true,
        'signatureVersion' => true,
        'signingName' => true,
        'serviceFullName' => true,
        'protocol' => true,
        'targetPrefix' => true,
        'jsonVersion' => true,
        'errorPrefix' => true,
        'timestampFormat' => true, # glacier api customization
        'xmlNamespace' => true,

        # ignore
        'apiVersion' => false,
        'checksumFormat' => false,
        'globalEndpoint' => false,
        'serviceAbbreviation' => false,
      }

      # @option options [required, Hash] :api
      # @option options [required, Hash, nil] :paginators
      def initialize(options)
        @api = options.fetch(:api)
        @paginators = options.fetch(:paginators)
        super('ClientApi')
        docstring("@api private")
        include('Seahorse::Model')
        apply_shape_classes(self)
        apply_shape_definitions(self)
        apply_api_const(self)
      end

      private

      def metadata
        Dsl::CodeLiteral.new do |c|
          c << "api.metadata = {"
          c.indent do
            (@api['metadata'] || {}).keys.sort.each do |key|
              if METADATA_KEYS[key]
                c << "#{key.inspect} => #{@api['metadata'][key].inspect},"
              elsif METADATA_KEYS[key].nil?
                raise "unhandled metadata key #{key.inspect}"
              end
            end
          end
          c << "}"
        end
      end

      def operations
        (@api['operations'] || {}).map do |name, operation|
          operation(name, operation)
        end
      end

      def operation(name, operation)
        Dsl::CodeLiteral.new do |code|
          code << "api.add_operation(:#{underscore(name)}, Seahorse::Model::Operation.new.tap do |o|"
          code.indent do |c|
            c << "o.name = #{name.inspect}"
            c << "o.http_method = #{operation['http']['method'].inspect}"
            c << "o.http_request_uri = #{operation['http']['requestUri'].inspect}"
            c << "o.deprecated = true" if operation['deprecated']
            c << "o['authtype'] = #{operation['authtype'].inspect}" if operation['authtype']
            %w(input output).each do |mode|
              c << "o.#{mode} = #{operation_shape_ref(operation[mode])}"
            end
            Array(operation['errors']).each do |error|
              c << "o.errors << #{operation_shape_ref(error)}"
            end
            apply_operation_pager(c, name)
          end
          code << "end)"
        end
      end

      def operation_shape_ref(ref)
        if ref
          metadata = ref.dup
          shape_name = metadata.delete('shape')
          if metadata.empty?
            options = ''
          else
            options = {}
            metadata.each_pair do |key, value|
              next if key == 'resultWrapper'
              if key == 'locationName'
                options[:location_name] = value.inspect
              else
                options[:metadata] ||= {}
                options[:metadata][key] = value.inspect
              end
            end
            if options.empty?
              options = ''
            else
              options = ', ' + HashFormatter.new(wrap:false).format(options)
            end
          end
          "Shapes::ShapeRef.new(shape: #{shape_name}#{options})"
        else
          "Shapes::ShapeRef.new(shape: Shapes::StructureShape.new(struct_class: Aws::EmptyStructure))"
        end
      end

      def shape_ref(ref, member_name = nil, required = Set.new)
        line = "Shapes::ShapeRef.new(shape: #{ref['shape']}"
        line += shape_ref_required(required, member_name)
        line += shape_ref_deprecated(ref)
        line += shape_ref_location(ref)
        line += shape_ref_location_name(member_name, ref)
        line += shape_ref_metadata(ref)
        line += ")"
        line
      end

      def apply_operation_pager(code, operation_name)
        if @paginators && @paginators['pagination'][operation_name]
          rules = @paginators['pagination'][operation_name]
          rules = HashFormatter.new(
            quote_strings: true,
            inline: true,
            wrap: false,
          ).format(rules)
          code << "o[:pager] = Aws::Pager.new(#{rules})"
        end
      end

      def apply_shape_classes(m)
        m.code do |c|
          shape_defs.each do |shape_name, shape|
            attrs = []
            attrs << "name: '#{shape_name}'"
            shape.each_pair do |key, value|
              if SHAPE_KEYS[key]
                attrs << "#{key}: #{value.inspect}"
              elsif SHAPE_KEYS[key].nil?
                raise "unhandled shape key #{key.inspect}"
              end
            end
            attrs = attrs.join(', ')
            c << "#{shape_name} = Shapes::#{shape_class(shape['type'])}.new(#{attrs})"
          end
        end
      end

      def apply_shape_definitions(m)
        m.code do |c|
          shape_defs.each do |shape_name, shape|
            if shape['type'] == 'structure' && !shape['error'] && !shape['exception']
              required = Set.new(shape['required'] || [])
              shape['members'].each do |member_name, member_ref|
                c << "#{shape_name}.add_member(:#{underscore(member_name)}, #{shape_ref(member_ref, member_name, required)})"
              end
              c << "#{shape_name}.struct_class = Types::#{shape_name}"
              if payload = shape['payload']
                c << "#{shape_name}[:payload] = :#{underscore(payload)}"
                c << "#{shape_name}[:payload_member] = #{shape_name}.member(:#{underscore(payload)})"
              end
            elsif shape['type'] == 'list'
              c << "#{shape_name}.member = #{shape_ref(shape['member'])}"
            elsif shape['type'] == 'map'
              c << "#{shape_name}.key = #{shape_ref(shape['key'])}"
              c << "#{shape_name}.value = #{shape_ref(shape['value'])}"
            else
              next
            end
            c.newline
          end
        end
      end

      def apply_api_const(m)
        m.code do |c|
          c << "# @api private"
          c << "API = Seahorse::Model::Api.new.tap do |api|"
          c.indent do
            c.newline
            if @api['metadata'] && @api['metadata']['apiVersion']
              c << "api.version = #{@api['metadata']['apiVersion'].inspect}"
              c.newline
            end
            c << metadata
            operations.each do |operation|
              c.newline
              c << operation
            end
          end
          c << "end"
        end
      end

      def shape_ref_required(required, member_name)
        if required.include?(member_name)
          ", required: true"
        else
          ""
        end
      end

      def shape_ref_deprecated(ref)
        if ref['deprecated'] || @api['shapes'][ref['shape']]['deprecated']
          ", deprecated: true"
        else
          ""
        end
      end

      def shape_ref_location(ref)
        if ref['location']
          ", location: #{ref['location'].inspect}"
        else
          ''
        end
      end

      def shape_ref_location_name(member_name, member_ref)
        location_name = member_ref['locationName']
        location_name ||= member_name unless member_ref['location'] == 'headers'
        location_name ? ", location_name: #{location_name.inspect}" : ""
      end

      def shape_ref_metadata(member_ref)
        metadata = member_ref.inject({}) do |hash, (key, value)|
          hash[key] = value unless SKIP_TRAITS.include?(key)
          hash
        end
        if metadata.empty?
          ""
        else
          ", metadata: #{metadata.inspect}"
        end
      end

      def shape_class(type)
        if SHAPE_CLASSES.key?(type)
          SHAPE_CLASSES[type]
        else
          raise ArgumentError, "unsupported shape type `#{type}'"
        end
      end

      def shape_defs
        Enumerator.new do |y|
          (@api['shapes'] || {}).keys.sort.each do |shape_name|
            y.yield(shape_name, @api['shapes'][shape_name])
          end
        end
      end

      def structure_defs
        Enumerator.new do |y|
          shape_defs.each do |shape_name, shape|
            if shape['type'] == 'structure' && !shape['error'] && !shape['exception']
              y.yield(shape_name, shape)
            end
          end
        end
      end

    end
  end
end
