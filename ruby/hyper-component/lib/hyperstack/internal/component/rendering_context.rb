module Hyperstack
  module Internal
    module Component
      class RenderingContext
        class NotQuiet < Exception; end
        class << self
          attr_accessor :waiting_on_resources

          def raise_if_not_quiet?
            @raise_if_not_quiet
          end

          def raise_if_not_quiet=(x)
            @raise_if_not_quiet = x
          end

          def quiet_test(component)
            return unless component.waiting_on_resources && raise_if_not_quiet? #&& component.class != RescueMetaWrapper <- WHY  can't create a spec that this fails without this, but several fail with it.
            raise NotQuiet.new("#{component} is waiting on resources")
          end

          def render(name, *args, &block)
            was_outer_most = !@not_outer_most
            @not_outer_most = true
            remove_nodes_from_args(args)
            @buffer ||= [] unless @buffer
            if block
              element = build do
                saved_waiting_on_resources = nil #waiting_on_resources  what was the purpose of this its used below to or in with the current elements waiting_for_resources
                self.waiting_on_resources = nil
                run_child_block(name.nil?, &block)
                if name
                  buffer = @buffer.dup
                  ReactWrapper.create_element(name, *args) { buffer }.tap do |element|
                    element.waiting_on_resources = saved_waiting_on_resources || !!buffer.detect { |e| e.waiting_on_resources if e.respond_to?(:waiting_on_resources) }
                    element.waiting_on_resources ||= waiting_on_resources if buffer.last.is_a?(String)
                  end
                elsif @buffer.last.is_a? Hyperstack::Component::Element
                  @buffer.last.tap { |element| element.waiting_on_resources ||= saved_waiting_on_resources }
                else
                  buffer_s = @buffer.last.to_s
                  RenderingContext.render(:span) { buffer_s }.tap { |element| element.waiting_on_resources = saved_waiting_on_resources }
                end
              end
            elsif name.is_a? Hyperstack::Component::Element
              element = name
            else
              element = ReactWrapper.create_element(name, *args)
              element.waiting_on_resources = waiting_on_resources
            end
            @buffer << element
            self.waiting_on_resources = nil
            element
          ensure
            @not_outer_most = @buffer = nil if was_outer_most
          end

          def build
            current = @buffer
            @buffer = []
            return_val = yield @buffer
            @buffer = current
            return_val
          end

          def delete(element)
            @buffer.delete(element)
            element
          end
          alias as_node delete

          def rendered?(element)
            @buffer.include? element
          end

          def replace(e1, e2)
            @buffer[@buffer.index(e1)] = e2
          end

          def remove_nodes_from_args(args)
            args[0].each do |key, value|
              begin
                value.delete if value.is_a?(Hyperstack::Component::Element) # deletes Element from buffer
              rescue Exception
              end
            end if args[0] && args[0].is_a?(Hash)
          end

          # run_child_block gathers the element(s) generated by a child block.
          # for example when rendering this div: div { "hello".span; "goodby".span }
          # two child Elements will be generated.
          #
          # the final value of the block should either be
          #   1 an object that responds to :acts_as_string?
          #   2 a string,
          #   3 an element that is NOT yet pushed on the rendering buffer
          #   4 or the last element pushed on the buffer
          #
          # in case 1 we render a span
          # in case 2 we automatically push the string onto the buffer
          # in case 3 we also push the Element onto the buffer IF the buffer is empty
          # case 4 requires no special processing
          #
          # Once we have taken care of these special cases we do a check IF we are in an
          # outer rendering scope.  In this case react only allows us to generate 1 Element
          # so we insure that is the case, and also check to make sure that element in the buffer
          # is the element returned

          def run_child_block(is_outer_scope)
            result = yield
            if result.respond_to?(:acts_as_string?) && result.acts_as_string?
              # hyper-mesh DummyValues respond to acts_as_string, and must
              # be converted to spans INSIDE the parent, otherwise the waiting_on_resources
              # flag will get set in the wrong context
              RenderingContext.render(:span) { result.to_s }
            elsif result.is_a?(String) || (result.is_a?(Hyperstack::Component::Element) && @buffer.empty?)
              @buffer << result
            end
            raise_render_error(result) if is_outer_scope && @buffer != [result]
          end

          # heurestically raise a meaningful error based on the situation

          def raise_render_error(result)
            improper_render 'A different element was returned than was generated within the DSL.',
                            'Possibly improper use of Element#delete.' if @buffer.count == 1
            improper_render "Instead #{@buffer.count} elements were generated.",
                            'Do you want to wrap your elements in a div?' if @buffer.count > 1
            improper_render "Instead the component #{result} was returned.",
                            "Did you mean #{result}()?" if result.try :hyper_component?
            improper_render "Instead the #{result.class} #{result} was returned.",
                            'You may need to convert this to a string.'
          end

          def improper_render(message, solution)
            raise "a component's render method must generate and return exactly 1 element or a string.\n"\
                  "    #{message}  #{solution}"
          end
        end
      end
    end
  end
end

class Object
  [:span, :td, :th].each do |tag|
    define_method(tag) do |*args, &block|
      args.unshift(tag)
      # legacy hyperloop allowed tags to be lower case as well so if self is a component
      # then this is just a DSL method for example:
      # render(:div) do
      #   span { 'foo' }
      # end
      # in this case self is just the component being rendered, so span is just a method
      # in the component.
      # If we fully deprecate lowercase tags, then this next line can go...
      return send(*args, &block) if respond_to?(:hyper_component?) && hyper_component?
      Hyperstack::Internal::Component::RenderingContext.render(*args) { to_s }
    end
  end


  def para(*args, &block)
    args.unshift(:p)
    # see above comment
    return send(*args, &block) if respond_to?(:hyper_component?) && hyper_component?
    Hyperstack::Internal::Component::RenderingContext.render(*args) { to_s }
  end

  def br
    # see above comment
    return send(:br) if respond_to?(:hyper_component?) && hyper_component?
    Hyperstack::Internal::Component::RenderingContext.render(:span) do
      Hyperstack::Internal::Component::RenderingContext.render(to_s)
      Hyperstack::Internal::Component::RenderingContext.render(:br)
    end
  end

end
