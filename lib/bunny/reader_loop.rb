require "thread"

module Bunny
  # Network activity loop that reads and passes incoming AMQP 0.9.1 methods for
  # processing. They are dispatched further down the line in Bunny::Session and Bunny::Channel.
  # This loop uses a separate thread internally.
  #
  # This mimics the way RabbitMQ Java is designed quite closely.
  # @private
  class ReaderLoop

    def initialize(transport, session, session_thread)
      @transport      = transport
      @session        = session
      @session_thread = session_thread
      @logger         = @session.logger

      @mutex          = Mutex.new

      @stopping        = false
      @stopped         = false
      @network_is_down = false
    end


    def start
      @thread    = Thread.new(&method(:run_loop))
    end

    def resume
      start
    end


    def run_loop
      loop do
        begin
          break if @mutex.synchronize { @stopping || @stopped || @network_is_down }
          run_once
        rescue AMQ::Protocol::EmptyResponseError, IOError, SystemCallError, Timeout::Error => e
          break if terminate? || @session.closing? || @session.closed?

          @network_is_down = true
          if @session.automatically_recover?
            log_exception(e, level: :warn)
            @session.handle_network_failure(e)
          else
            log_exception(e)
            @session_thread.raise(Bunny::NetworkFailure.new("detected a network failure: #{e.message}", e))
          end
        rescue ShutdownSignal => _
          @mutex.synchronize { @stopping = true }
          break
        rescue Exception => e
          break if terminate?
          if !(@session.closing? || @session.closed?)
            log_exception(e)

            @network_is_down = true
            @session_thread.raise(Bunny::NetworkFailure.new("caught an unexpected exception in the network loop: #{e.message}", e))
          end
        rescue Errno::EBADF => _ebadf
          break if terminate?
          # ignored, happens when we loop after the transport has already been closed
          @mutex.synchronize { @stopping = true }
        end
      end

      @mutex.synchronize { @stopped = true }
    end

    def run_once
      frame = @transport.read_next_frame
      return if frame.is_a?(AMQ::Protocol::HeartbeatFrame)

      if !frame.final? || frame.method_class.has_content?
        header   = @transport.read_next_frame
        content  = ''

        if header.body_size > 0
          loop do
            body_frame = @transport.read_next_frame
            content << body_frame.decode_payload

            break if content.bytesize >= header.body_size
          end
        end

        @session.handle_frameset(frame.channel, [frame.decode_payload, header.decode_payload, content])
      else
        @session.handle_frame(frame.channel, frame.decode_payload)
      end
    end

    def stop
      @mutex.synchronize { @stopping = true }
    end

    def stopped?
      @mutex.synchronize { @stopped }
    end

    def stopping?
      @mutex.synchronize { @stopping }
    end

    def terminate_with(e)
      @mutex.synchronize { @stopping = true }

      self.raise(e)
    end

    def raise(e)
      @thread.raise(e) if @thread
    end

    def join
      @thread.join if @thread
    end

    def kill
      if @thread
        @thread.kill
        @thread.join
      end
    end

    protected

    def log_exception(e, level: :error)
      if !(io_error?(e) && (@session.closing? || @session.closed?))
        @logger.send level, "Exception in the reader loop: #{e.class.name}: #{e.message}"
        @logger.send level, "Backtrace: "
        e.backtrace.each do |line|
          @logger.send level, "\t#{line}"
        end
      end
    end

    def io_error?(e)
      [AMQ::Protocol::EmptyResponseError, IOError, SystemCallError].any? do |klazz|
        e.is_a?(klazz)
      end
    end

    def terminate?
      @mutex.synchronize { @stopping || @stopped }
    end
  end
end
