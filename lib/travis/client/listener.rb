require 'travis/client'
require 'forwardable'
require 'json'

if require 'pusher-client'
  # it's us that has been loading pusher-client
  # so let's assume we can mess with it - yay for global state
  PusherClient.logger.level = 2
end

module Travis
  module Client
    class Listener
      class Socket < PusherClient::Socket
        attr_accessor :session, :signatures
        def initialize(application_key, options = {})
          @session    = options.fetch(:session)
          @signatures = {}
          super
        end

        def subscribe_all
          # bulk auth on connect
          fetch_auth(*channels.channels.keys)
          super
        end

        def fetch_auth(*channels)
          channels.select! { |c| signatures[c].nil? if c.start_with? 'private-' }
          signatures.merge! session.post_raw('/pusher/auth', :channels => channels, :socket_id => socket_id)['channels'] if channels.any?
        end

        def get_private_auth(channel)
          fetch_auth(channel.name)
          signatures[channel.name]
        end
      end

      EVENTS = %w[
        build:created build:started build:finished
        job:created job:started job:log job:finished
      ]

      Event = Struct.new(:type, :repository, :build, :job, :payload)

      class EntityListener
        attr_reader :listener, :entities

        extend Forwardable
        def_delegators :listener, :disconnect, :on_connect, :subscribe

        def initialize(listener, entities)
          @listener, @entities = listener, Array(entities)
        end

        def on(*events)
          listener.on(*events) { |e| yield(e) if dispatch?(e) }
        end

        private

          def dispatch?(event)
            entities.include? event.repository or
            entities.include? event.build      or
            entities.include? event.job
          end
      end

      attr_reader :session, :socket

      def initialize(session)
        @session   = session
        @socket    = Socket.new(pusher_key, :encrypted => true, :session => session)
        @channels  = []
        @callbacks = []
      end

      def subscribe(*entities)
        entities = entities.map do |entity|
          entity = entity.pusher_entity while entity.respond_to? :pusher_entity
          @channels.concat(entity.pusher_channels)
          entity
        end

        yield entities.any? ? EntityListener.new(self, entities) : self if block_given?
      end

      def on(*events, &block)
        events = events.flat_map { |e| e.respond_to?(:to_str) ? e.to_str : EVENTS.grep(e) }.uniq
        events.each { |e| @callbacks << [e, block] }
      end

      def on_connect
        socket.bind('pusher:connection_established') { yield }
      end

      def listen
        @channels = default_channels if @channels.empty?
        @channels.map! { |c| c.start_with?('private-') ? c : "private-#{c}" } if session.private_channels?
        @channels.uniq.each { |c| socket.subscribe(c) }
        @callbacks.each { |e,b| socket.bind(e) { |d| dispatch(e, d, &b) } }
        socket.connect
      end

      def disconnect
        socket.disconnect
      end

      private

        def dispatch(type, json)
          payload  = JSON.parse(json)
          entities = session.load format_payload(type, payload)
          yield Event.new(type, entities['repository'], entities['build'], entities['job'], payload)
        end

        def format_payload(type, payload)
          case type
          when "job:log" then format_log(payload)
          when /job:/    then format_job(payload)
          else payload
          end
        end

        def format_job(payload)
          build           = { "id" => payload["build_id"],      "repository_id" => payload["repository_id"]   }
          repo            = { "id" => payload["repository_id"], "slug"          => payload["repository_slug"] }
          build["number"] = payload["number"][/^[^\.]+/] if payload["number"]
          { "job" => payload, "build" => build, "repository" => repo }
        end

        def format_log(payload)
          job = session.job(payload['id'])
          { "job" => { "id" => job.id }, "build" => { "id" => job.build.id }, "repository" => { "id" => job.repository.id } }
        end

        def default_channels
          return ['common'] if session.access_token.nil?
          session.user.channels
        end

        def pusher_key
          session.config.fetch('pusher').fetch('key')
        rescue IndexError
          raise Travis::Client::Error, "#{session.api_endpoint} is missing pusher key"
        end
    end
  end
end
