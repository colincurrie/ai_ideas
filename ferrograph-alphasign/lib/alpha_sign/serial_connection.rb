begin
  require "serialport"
rescue LoadError
  # Reported lazily in #open so commands like `list-modes` or `--dry-run`
  # work without the gem (and its native extension) installed.
end

module AlphaSign
  class SerialConnection
    PARITY = {
      "none" => 0, # SerialPort::NONE
      "even" => 1, # SerialPort::EVEN
      "odd" => 2   # SerialPort::ODD
    }.freeze

    def initialize(device:, baud: 9600, data_bits: 8, stop_bits: 1, parity: "none")
      raise ArgumentError, "unknown parity #{parity.inspect}; use one of #{PARITY.keys.join(', ')}" unless PARITY.key?(parity)

      @device = device
      @baud = baud
      @data_bits = data_bits
      @stop_bits = stop_bits
      @parity = parity
      @port = nil
    end

    def open
      unless defined?(SerialPort)
        raise LoadError, "the 'serialport' gem is required to talk to a real serial port. " \
                          "Run `bundle install` (see README.md) or `gem install serialport`."
      end

      @port = SerialPort.new(@device, @baud, @data_bits, @stop_bits, PARITY.fetch(@parity))
      @port.read_timeout = 1000
      self
    end

    def write(packet)
      open unless @port
      @port.write(packet.to_s)
      @port.flush
    rescue StandardError
      # Drop the (possibly dead) port so a long-running caller - e.g. a
      # daemon that outlives a USB adapter being unplugged/replugged - will
      # attempt a fresh #open on the next write, rather than repeatedly
      # failing against a stale handle.
      close
      raise
    end

    # Sends a read request and waits for the sign's reply.
    #
    # Replies are read a byte at a time until <EOT> arrives or +timeout+
    # seconds pass. Byte-at-a-time is not as slow as it looks - each read
    # blocks on the port rather than spinning - and it means a reply is
    # returned the moment it ends rather than after waiting out a timeout,
    # which matters because a Memory Dump can be many kilobytes at 9600
    # baud while a "file is empty" reply is a dozen bytes.
    #
    # Anything already sitting in the input buffer is discarded first: on a
    # link this library has only ever written to, that's either noise or
    # the tail of an earlier reply nobody read, and either would corrupt
    # this one.
    def transact(packet, timeout: 5)
      open unless @port
      flush_input
      @port.write(packet.to_s)
      @port.flush
      Response.new(read_until_eot(timeout))
    rescue StandardError
      close
      raise
    end

    def close
      @port&.close
    rescue StandardError
      # Already broken; nothing sensible to do with a close error here.
    ensure
      @port = nil
    end

    # True once #open (or a successful #write) has established a port.
    # Note this doesn't guarantee the underlying device is still present -
    # only that we haven't detected it being gone yet (see #write).
    def connected?
      !@port.nil?
    end
    private

    def flush_input
      @port.flush_input if @port.respond_to?(:flush_input)
    rescue StandardError
      # Not every port implementation offers this; it's a tidy-up, not a
      # requirement.
    end

    def read_until_eot(timeout)
      deadline = monotonic_now + timeout
      buffer = +""
      buffer.force_encoding(Encoding::ASCII_8BIT)

      while monotonic_now < deadline
        byte = @port.read(1)
        if byte.nil? || byte.empty?
          # Read timed out with nothing on the wire. Once something has
          # arrived, a gap means the reply ended without an EOT we
          # recognise - stop rather than block for the whole timeout.
          break unless buffer.empty?

          next
        end
        buffer << byte
        break if byte == Protocol::EOT
      end

      buffer
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end