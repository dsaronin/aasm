module AASM
  class InvalidTransition < RuntimeError
  end

  class UndefinedState < RuntimeError
  end

  def self.included(base) #:nodoc:
    base.extend AASM::ClassMethods

    AASM::Persistence.set_persistence(base)
    unless AASM::StateMachine[base]
      AASM::StateMachine[base] = AASM::StateMachine.new('')
    end
   super
  end

  module ClassMethods
    def inherited(klass)
      AASM::StateMachine[klass] = AASM::StateMachine[self].clone
      super
    end

    def aasm_initial_state(set_state=nil)
      if set_state
        AASM::StateMachine[self].initial_state = set_state
      else
        AASM::StateMachine[self].initial_state
      end
    end

    def aasm_initial_state=(state)
      AASM::StateMachine[self].initial_state = state
    end

    def aasm_state(name, options={})
      sm = AASM::StateMachine[self]
      sm.create_state(name, options)
      sm.initial_state = name unless sm.initial_state

      define_method("#{name.to_s}?") do
        aasm_current_state == name
      end
    end
    
    def aasm_event(name, options = {}, &block)
      sm = AASM::StateMachine[self]

      unless sm.events.has_key?(name)
        sm.events[name] = AASM::SupportingClasses::Event.new(name, options, &block)
      end

      # an addition over standard aasm so that, before firing an event, you can ask
      # may_event? and get back a boolean that tells you whether the guard method
      # on the transition will let this happen.
      define_method("may_#{name.to_s}?") do |*args|
        aasm_test_event(name, *args)
      end
      
      define_method("#{name.to_s}!") do |*args|
        aasm_fire_event(name, true, *args)
      end

      define_method("#{name.to_s}") do |*args|
        aasm_fire_event(name, false, *args)
      end
    end

    def aasm_states
      AASM::StateMachine[self].states
    end

    def aasm_events
      AASM::StateMachine[self].events
    end

    def aasm_states_for_select
      AASM::StateMachine[self].states.map { |state| state.for_select }
    end

    def human_event_name(event)
      AASM::Localizer.new.human_event_name(self, event)
    end
  end
  
  # Instance methods
  def aasm_current_state
    return @aasm_current_state if @aasm_current_state

    if self.respond_to?(:aasm_read_state) || self.private_methods.include?('aasm_read_state')
      @aasm_current_state = aasm_read_state
    end
    return @aasm_current_state if @aasm_current_state

    aasm_enter_initial_state
  end

  def aasm_enter_initial_state
    state_name = aasm_determine_state_name(self.class.aasm_initial_state)
    state = aasm_state_object_for_state(state_name)

    state.call_action(:before_enter, self)
    state.call_action(:enter, self)
    self.aasm_current_state = state_name
    state.call_action(:after_enter, self)

    state_name
  end

  def aasm_events_for_current_state
    aasm_events_for_state(aasm_current_state)
  end

  # filters the results of events_for_current_state so that only those that
  # are really currently possible (given transition guards) are shown.
  def aasm_permissible_events_for_current_state
    aasm_events_for_current_state.select{ |e| self.send(("may_" + e.to_s + "?").to_sym) }
  end
  
  def aasm_events_for_state(state)
    events = self.class.aasm_events.values.select {|event| event.transitions_from_state?(state) }
    events.map {|event| event.name}
  end

  def human_state
    AASM::Localizer.new.human_state(self)
  end

  private

  def set_aasm_current_state_with_persistence(state)
    save_success = true
    if self.respond_to?(:aasm_write_state) || self.private_methods.include?('aasm_write_state')
      save_success = aasm_write_state(state)
    end
    self.aasm_current_state = state if save_success

    save_success
  end

  def aasm_current_state=(state)
    if self.respond_to?(:aasm_write_state_without_persistence) || self.private_methods.include?('aasm_write_state_without_persistence')
      aasm_write_state_without_persistence(state)
    end
    @aasm_current_state = state
  end

  def aasm_determine_state_name(state)
    case state
      when Symbol, String
        state
      when Proc
        state.call(self)
      else
        raise NotImplementedError, "Unrecognized state-type given.  Expected Symbol, String, or Proc."
    end
  end

  def aasm_state_object_for_state(name)
    obj = self.class.aasm_states.find {|s| s == name}
    raise AASM::UndefinedState, "State :#{name} doesn't exist" if obj.nil?
    obj
  end

  def aasm_test_event(name, *args)
    event = self.class.aasm_events[name]
    event.may_fire?(self, *args)
  end
  

# dsaronin@gmail added  unless skip_callbacks_for_same_state_transitions
# aasm_state option: :same_state_skip => true IF skip state before/exit
# callbacks IFF the to/from states are the same
# default behavior is :same_state_skip => nil, which acts same as non-forked aasm
# thus invokes before/exit state callbacks.

# unfortunately, the first state call backs: old_state :exit should have this
# check done as well, but can't because we won't know the new_state until
# after fire.  we need a method separate from fire which determines the new
# state.

# kludge: created a non-DRY event.determine_new_state which duplicates event.fire
# except it doesn't do the execute.  That way the existing aasm code can run,
# be updated in future. we just duplicate it enough to learn the new_state
# and figure out if we need the skip callback or not

  def aasm_fire_event(name, persist, *args)
    event = self.class.aasm_events[name]
    begin
      old_state = aasm_state_object_for_state(aasm_current_state)

      new_state_name = event.determine_new_state(self, *args)
      skip_callbacks_for_same_state_transitions = new_state_name && old_state.options[:same_state_skip] && (old_state.name == new_state_name)

      old_state.call_action(:exit, self)  unless skip_callbacks_for_same_state_transitions

      # new event before callback
      event.call_action(:before, self)

      new_state_name = event.fire(self, *args)

      unless new_state_name.nil?
        new_state = aasm_state_object_for_state(new_state_name)
        
        # new before_ callbacks
        old_state.call_action(:before_exit, self)  unless skip_callbacks_for_same_state_transitions
        new_state.call_action(:before_enter, self) unless skip_callbacks_for_same_state_transitions

        new_state.call_action(:enter, self) unless skip_callbacks_for_same_state_transitions

        persist_successful = true
        if persist
          persist_successful = set_aasm_current_state_with_persistence(new_state_name)
          event.execute_success_callback(self) if persist_successful
        else
          self.aasm_current_state = new_state_name
        end

        if persist_successful
          old_state.call_action(:after_exit, self) unless skip_callbacks_for_same_state_transitions
          new_state.call_action(:after_enter, self) unless skip_callbacks_for_same_state_transitions
          event.call_action(:after, self)

          self.aasm_event_fired(name, old_state.name, self.aasm_current_state) if self.respond_to?(:aasm_event_fired)
        else
          self.aasm_event_failed(name, old_state.name) if self.respond_to?(:aasm_event_failed)
        end

        persist_successful
      else
        if self.respond_to?(:aasm_event_failed)
          self.aasm_event_failed(name, old_state.name)
        end

        false
      end
    rescue StandardError => e
      event.execute_error_callback(self, e)
    end
  end
end
