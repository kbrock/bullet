module Bullet
  module ActiveRecord
    def self.enable
      require 'active_record'
      ::ActiveRecord::Relation.class_eval do
        alias_method :origin_to_a, :to_a
        # if select a collection of objects, then these objects have possible to cause N+1 query.
        # if select only one object, then the only one object has impossible to cause N+1 query.
        def to_a
          records = origin_to_a
          if records.first.class.name !~ /^HABTM_/
            if records.size > 1
              Bullet::Detector::NPlusOneQuery.add_possible_objects(records)
              Bullet::Detector::CounterCache.add_possible_objects(records)
            elsif records.size == 1
              Bullet::Detector::NPlusOneQuery.add_impossible_object(records.first)
              Bullet::Detector::CounterCache.add_impossible_object(records.first)
            end
          end
          records
        end
      end

      ::ActiveRecord::Associations::Preloader.class_eval do
        alias_method :origin_preloaders_on, :preloaders_on

        def preloaders_on(association, records, scope)
          if records.first.class.name !~ /^HABTM_/
            records.each do |record|
              Bullet::Detector::Association.add_object_associations(record, association)
            end
            Bullet::Detector::UnusedEagerLoading.add_eager_loadings(records, association)
          end
          origin_preloaders_on(association, records, scope)
        end
      end

      ::ActiveRecord::FinderMethods.class_eval do
        # add includes in scope
        alias_method :origin_find_with_associations, :find_with_associations
        def find_with_associations
          records = origin_find_with_associations
          associations = (eager_load_values + includes_values).uniq
          records.each do |record|
            Bullet::Detector::Association.add_object_associations(record, associations)
          end
          Bullet::Detector::UnusedEagerLoading.add_eager_loadings(records, associations)
          records
        end
      end

      ::ActiveRecord::Associations::JoinDependency.class_eval do
        alias_method :origin_instantiate, :instantiate
        alias_method :origin_construct_model, :construct_model

        def instantiate(result_set, aliases)
          @bullet_eager_loadings = {}
          records = origin_instantiate(result_set, aliases)

          @bullet_eager_loadings.each do |klazz, eager_loadings_hash|
            objects = eager_loadings_hash.keys
            Bullet::Detector::UnusedEagerLoading.add_eager_loadings(objects, eager_loadings_hash[objects.first].to_a)
          end
          records
        end

        # call join associations
        def construct_model(record, node, row, model_cache, id, aliases)
          result = origin_construct_model(record, node, row, model_cache, id, aliases)

          associations = node.reflection.name
          Bullet::Detector::Association.add_object_associations(record, associations)
          Bullet::Detector::NPlusOneQuery.call_association(record, associations)
          @bullet_eager_loadings[record.class] ||= {}
          @bullet_eager_loadings[record.class][record] ||= Set.new
          @bullet_eager_loadings[record.class][record] << associations

          result
        end
      end

      ::ActiveRecord::Associations::CollectionAssociation.class_eval do
        # call one to many associations
        alias_method :origin_load_target, :load_target
        def load_target
          Bullet::Detector::NPlusOneQuery.call_association(@owner, @reflection.name) unless @inversed
          origin_load_target
        end

        alias_method :origin_empty?, :empty?
        def empty?
          Bullet::Detector::NPlusOneQuery.call_association(@owner, @reflection.name)
          origin_empty?
        end
      end

      ::ActiveRecord::Associations::SingularAssociation.class_eval do
        # call has_one and belongs_to associations
        alias_method :origin_reader, :reader
        def reader(force_reload = false)
          result = origin_reader(force_reload)
          if @owner.class.name !~ /^HABTM_/
            Bullet::Detector::NPlusOneQuery.call_association(@owner, @reflection.name) unless @inversed
            Bullet::Detector::NPlusOneQuery.add_possible_objects(result)
          end
          result
        end
      end

      ::ActiveRecord::Associations::HasManyAssociation.class_eval do
        alias_method :origin_has_cached_counter?, :has_cached_counter?

        def has_cached_counter?(reflection = reflection())
          result = origin_has_cached_counter?(reflection)
          Bullet::Detector::CounterCache.add_counter_cache(owner, reflection.name) unless result
          result
        end
      end
    end
  end
end
