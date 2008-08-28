require 'active_record/fixtures'

class ActiveRecord::Base
  class << self
    alias_method :has_one_without_cti, :has_one
    
    def cti?
      false
    end
  end

  def self.class_table_inheritance(options = {})
    table_name = options[:subclass_table] || name.demodulize.tableize
    primary_key_name = options[:subclass_foreign_key] || "#{superclass.name.demodulize.underscore}_id" 

    proxy_symbol = "extra_columns_for_#{name.demodulize.underscore}".to_sym
    class_name = '::' + self.name

    proxy_class = const_set('ExtraColumns', Class.new(ActiveRecord::Base))
    parent_reflections = superclass.reflections.map {|r| ":#{r[0].to_s}"}

    proxy_class.class_eval do
      set_table_name table_name
      set_primary_key primary_key_name
      belongs_to :base, :class_name => class_name, :foreign_key => primary_key_name
      def self.reloadable?; false; end
      def self.wrapper_class; class_name.constantize; end
    end

    has_one_without_cti proxy_symbol, :class_name => proxy_class.name, :foreign_key => primary_key_name, :dependent => :destroy

    # We need the after_save filter for this association to run /before/ any other after_save's already registered on the superclass,
    # and before any after_creates or after_updates. This calls for some hackery:

    if RAILS_GEM_VERSION.start_with?("2.0")
      proxy_save_callback = @inheritable_attributes[:after_save].pop
      @inheritable_attributes[:after_create] ||= []
      @inheritable_attributes[:after_create].unshift(proxy_save_callback)
      @inheritable_attributes[:after_update] ||= []
      @inheritable_attributes[:after_update].unshift(proxy_save_callback)
    else
      proxy_save_callback = @after_save_callbacks.pop
      @after_create_callbacks ||= CallbackChain.new
      @after_create_callbacks.unshift(proxy_save_callback)
      @after_update_callbacks ||= CallbackChain.new
      @after_update_callbacks.unshift(proxy_save_callback)
    end
    
    includes_string = <<-EOI
      if params.last.is_a?(Hash)
        opts = params.last
      else
        opts = {}
        params.push(opts)
      end
      old_includes = opts[:include]
      if old_includes
        old_includes = [old_includes.to_sym] if old_includes.kind_of? String
        old_includes = [old_includes] if old_includes.kind_of? Symbol
        opts[:include] = []
        proxy_includes = []
        while i = old_includes.shift do
          if [#{parent_reflections.join(',')}].include?(i.to_sym)
            opts[:include] << i.to_sym 
          else
            proxy_includes << i.to_sym
          end
        end
        opts[:include] << {:#{proxy_symbol} => proxy_includes}
      else
        opts[:include] = [:#{proxy_symbol}]
      end
    EOI
    
    class_eval <<-EOV
      
      def self.cti?
        true
      end
      
      # This has been copied from active_record/associations.rb
      def self.create_extension_modules(association_id, block_extension, extensions)
        extension_module_name = "\#{self.to_s}\#{association_id.to_s.camelize}AssociationExtension"

        silence_warnings do
          Object.const_set(extension_module_name, Module.new(&block_extension))
        end

        Array(extensions).push(extension_module_name.constantize)
      end
      
      def self.find(*params)
        #{includes_string}
        opts[:limit] = 1 if params.first == :first
        super(*params)
      end
      
      def self.count(*params)
        #{includes_string}
        super(*params)
      end

      alias_method :#{proxy_symbol}_old, :#{proxy_symbol}
      def #{proxy_symbol}
        #{proxy_symbol}_old or self.#{proxy_symbol} = ExtraColumns.new
      end
      def save
        self.#{proxy_symbol} ||= ExtraColumns.new
        super
      end
      def save!
        self.#{proxy_symbol} ||= ExtraColumns.new
        super
      end
      # this doesn't happen automatically on update, so we'll make it:
      after_update {|record| record.#{proxy_symbol}.save }

      # associations on this subclass get added to the proxy class, and then the relevant methods delegated to the proxy object
      def self.belongs_to(name, *params)
        #params[0] =  {:foreign_key => "#{table_name.to_s.singularize.foreign_key}"}.merge(params[0] ? params[0] : {})
        ExtraColumns.belongs_to(name, *params)
        delegate name, "\#{name}=".to_sym, "\#{name}?".to_sym, "build_\#{name}".to_sym, "create_\#{name}".to_sym, :to => :#{proxy_symbol}
      end

      def self.has_one(name, *params)
        params[0] =  {:foreign_key => "#{table_name.to_s.singularize.foreign_key}"}.merge(params[0] ? params[0] : {})
        ExtraColumns.has_one(name, *params)
        delegate name, "\#{name}=".to_sym, "build_\#{name}".to_sym, "create_\#{name}".to_sym, :to => :#{proxy_symbol}
      end

      def self.has_many(name, options = {}, &extension)
        options =  {:foreign_key => "#{table_name.to_s.singularize.foreign_key}"}.merge(options ? options : {})
        options[:extend] = create_extension_modules(name, extension, options[:extend])
        ExtraColumns.has_many(name, options)
        delegate name, "\#{name}=".to_sym, "\#{name.to_s.singularize}_ids=".to_sym, :to => :#{proxy_symbol}
        delegate "\#{name.to_s.singularize}_ids".to_sym, :to => :#{proxy_symbol}
      end

      def self.has_and_belongs_to_many(name, options = {}, &extension)
        #options =  {:foreign_key => "#{table_name.to_s.singularize.foreign_key}"}.merge(options ? options : {})
        options[:extend] = create_extension_modules(name, extension, options[:extend])
        ExtraColumns.has_and_belongs_to_many(name, options)
        delegate name, "\#{name}=".to_sym, "\#{name.to_s.singularize}_ids=".to_sym, :to => :#{proxy_symbol}
        delegate "\#{name.to_s.singularize}_ids".to_sym, :to => :#{proxy_symbol}
      end
    EOV

    delegate_methods = proxy_class.column_names + proxy_class.column_names.map {|name| "#{name}=".to_sym } + proxy_class.column_names.map {|name| "#{name}?".to_sym }
    delegate *(delegate_methods << {:to => proxy_symbol})
  end
end
  
class Fixtures < (RUBY_VERSION < '1.9' ? YAML::Omap : Hash)
  puts "Loading CTI override for Fixtures"
  alias_method :has_primary_key_column_without_cti?, :has_primary_key_column? 
  def has_primary_key_column?
    if model_class.cti?
      return false
    else
      return has_primary_key_column_without_cti?
    end
  end
end 
