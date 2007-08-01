require 'net/ssh'
require 'net/sftp/constants'
require 'net/sftp/errors'
require 'net/sftp/packet'
require 'net/sftp/protocol'
require 'net/sftp/response'

module Net; module SFTP

  class Session
    include Net::SSH::Loggable
    include Net::SFTP::Constants

    HIGHEST_PROTOCOL_VERSION_SUPPORTED = 6

    attr_reader :session
    attr_reader :channel
    attr_reader :state
    attr_reader :input
    attr_reader :protocol
    attr_reader :pending_requests

    def initialize(session, &block)
      @session = session
      @input   = Net::SSH::Buffer.new
      self.logger = session.logger
      @state = :closed
      connect!(&block)
    end

    def close_channel
      channel.close
    end

    def connect!(&block)
      return unless state == :closed
      @state = :opening
      @channel = session.open_channel(&method(:when_channel_confirmed))
      @packet_length = nil
      @protocol = nil
      @on_ready = block
    end

    alias :loop_forever :loop
    def loop(&block)
      block ||= Proc.new { pending_requests.any? }
      session.loop(&block)
    end

    def send_packet(type, *args)
      data = Net::SSH::Buffer.from(*args)
      msg = Net::SSH::Buffer.from(:long, data.length+1, :byte, type, :raw, data)
      channel.send_data(msg.to_s)
    end

    public

      def open(path, flags=IO::RDONLY, mode=0640, &callback)
        id = protocol.open(path, flags, mode)
        pending_requests[id] = callback
        id
      end

      def close(handle, &callback)
        id = protocol.close(handle)
        pending_requests[id] = callback
        id
      end

      def read(handle, offset, length, &callback)
        id = protocol.read(handle, offset, length)
        pending_requests[id] = callback
        id
      end

      def write(handle, offset, data, &callback)
        id = protocol.write(handle, offset, data)
        pending_requests[id] = callback
        id
      end

    private

      def when_channel_confirmed(channel)
        debug { "requesting sftp subsystem" }
        @state = :subsystem
        channel.subsystem("sftp", &method(:when_subsystem_started))
      end

      def when_subsystem_started(channel, success)
        raise Net::SFTP::Exception, "could not start SFTP subsystem" unless success

        trace { "sftp subsystem successfully started" }
        @state = :init

        channel.on_data { |c,data| input.append(data) }
        channel.on_extended_data { |c,t,data| debug { data } }

        channel.on_close(&method(:when_channel_closed))
        channel.on_process(&method(:when_channel_polled))

        send_packet(FXP_INIT, :long, HIGHEST_PROTOCOL_VERSION_SUPPORTED)
      end

      def when_channel_closed(channel)
        trace { "sftp channel closed" }
        @channel = nil
        @state = :closed
      end

      MAP = {
        FXP_STATUS  => :status,
        FXP_HANDLE  => :handle,
        FXP_DATA    => :data,
        FXP_NAME    => :name,
        FXP_ATTRS   => :attrs
      }

      def when_channel_polled(channel)
        while input.length > 0
          if @packet_length.nil?
            # make sure we've read enough data to tell how long the packet is
            return unless input.length >= 4
            @packet_length = input.read_long
          end

          return unless input.length >= @packet_length
          packet = Net::SFTP::Packet.new(input.read(@packet_length))
          input.consume!
          @packet_length = nil

          trace { "received sftp packet #{packet.type} len #{packet.length}" }

          if packet.type == FXP_VERSION
            do_version(packet)
          elsif MAP.key?(packet.type)
            dispatch_request(MAP[packet.type], packet)
          else
            raise Net::SFTP::Exception, "unhandled packet #{packet.type}"
          end
        end
      end

      def do_version(packet)
        trace { "negotiating sftp protocol version, mine is #{HIGHEST_PROTOCOL_VERSION_SUPPORTED}" }

        server_version = packet.read_long
        trace { "server reports sftp version #{server_version}" }

        negotiated_version = [server_version, HIGHEST_PROTOCOL_VERSION_SUPPORTED].min
        debug { "negotiated version is #{negotiated_version}" }

        extensions = {}
        until packet.eof?
          name = packet.read_string
          data = packet.read_string
          extensions[name] = data
        end

        @protocol = Protocol.load(self, negotiated_version)
        @pending_requests = {}

        @state = :open
        @on_ready.call(self) if @on_ready
      end

      def dispatch_request(type, packet)
        id = packet.read_long
        callback = pending_requests.delete(id) or raise Net::SFTP::Exception, "no such request `#{id}'"
        parameters = protocol.send("parse_#{type}_packet", packet)

        if type == :status
          callback.call(Response.new(id, *parameters))
        else
          callback.call(Response.ok(id), *parameters)
        end
      end
  end

end; end