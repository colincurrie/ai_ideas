require "dotenv/load" # loads .env from the cwd (repo root, per README/DEPLOY.md) if present - never overrides already-set env vars (e.g. from systemd)
require "sinatra/base"
require "json"

require_relative "../lib/alpha_sign"
require_relative "config"

module SerialApi
  # The device driver service: owns the serial port and exposes the Alpha
  # protocol as JSON HTTP. No authentication - meant to be reachable only
  # from 127.0.0.1 (see web_app/, which is the authenticated front door).
  class App < Sinatra::Base
    configure do
      set :show_exceptions, false
      set :raise_errors, false
      # This service has no authentication of its own and relies entirely
      # on staying bound to 127.0.0.1 (see Config.bind / README) - Host
      # header validation adds little on top of that, and would otherwise
      # need configuring for every hostname a caller might use to reach
      # localhost. web_app (the authenticated, network-facing side) keeps
      # this protection active instead.
      set :host_authorization, permitted_hosts: []
      set :connection, AlphaSign::SerialConnection.new(
        device: Config.device, baud: Config.baud, parity: Config.parity,
        data_bits: Config.data_bits, stop_bits: Config.stop_bits
      )
      set :conn_mutex, Mutex.new
      set :last_error, nil
      set :sent_messages, {}
    end

    before do
      content_type :json
    end

    helpers do
      def json_body
        raw = request.body.read
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw, symbolize_names: true)
      rescue JSON::ParserError => e
        halt 400, { ok: false, error: "invalid JSON: #{e.message}" }.to_json
      end

      def truthy?(value)
        [true, "true", "1", 1].include?(value)
      end

      # Sends +packet+ over the serial port (guarded by a mutex, since the
      # sign only has one port), or just reports the bytes if +dry_run+.
      # +label+, when given, records this as the last-sent content for that
      # label so GET /messages can report it.
      def send_or_report(packet, dry_run:, label: nil, meta: {})
        if dry_run
          return { ok: true, dry_run: true, bytes_hex: packet.to_hex }
        end

        settings.conn_mutex.synchronize do
          settings.connection.write(packet)
        end
        settings.last_error = nil

        if label
          settings.sent_messages[label] = meta.merge(sent_at: Time.now.utc.iso8601)
        end

        { ok: true, bytes_hex: packet.to_hex, label: label }
      rescue StandardError, LoadError => e
        # LoadError isn't a StandardError, but SerialConnection#open
        # deliberately raises it when the 'serialport' gem isn't
        # installed (e.g. this machine has no hardware attached yet) -
        # that should surface as a normal API error, not a 500.
        settings.last_error = e.message
        halt 502, { ok: false, error: e.message }.to_json
      end

      def build_text_file(body, default_position: "fill", default_mode: "automode", label_override: nil, priority_override: nil)
        speed_prefix = body[:speed] ? AlphaSign::Speeds.lookup(body[:speed]) : ""
        text = speed_prefix + AlphaSign::Runs.encode(body[:runs] || [])

        AlphaSign::TextFile.new(
          text,
          label: label_override || body[:label] || "A",
          position: AlphaSign::Positions.lookup(body[:position] || default_position),
          mode: AlphaSign::Modes.lookup(body[:mode] || default_mode),
          priority: priority_override.nil? ? truthy?(body[:priority]) : priority_override
        )
      end

      def required_positive_int(body, key)
        value = body[key]
        halt 400, { ok: false, error: "#{key} is required" }.to_json if value.nil?

        int = Integer(value)
        halt 400, { ok: false, error: "#{key} must be positive" }.to_json unless int.positive?
        int
      rescue ArgumentError, TypeError
        halt 400, { ok: false, error: "#{key} must be an integer" }.to_json
      end

      # Best-effort size estimate for a previously-sent text label being
      # carried forward into a new Memory Configuration - there's no
      # tracked "defined size" for it (only the content last sent), so
      # this pads generously rather than trying to be exact.
      def estimate_text_size(meta)
        AlphaSign::Runs.encode(meta[:runs] || []).bytesize + 64
      end
    end

    error ArgumentError do
      status 400
      { ok: false, error: env["sinatra.error"].message }.to_json
    end

    get "/status" do
      {
        device: Config.device, baud: Config.baud, parity: Config.parity,
        data_bits: Config.data_bits, stop_bits: Config.stop_bits,
        address: Config.address, type: Config.type,
        connected: settings.connection.connected?,
        last_error: settings.last_error
      }.to_json
    end

    get "/options" do
      {
        modes: AlphaSign::Modes::NAMES.keys.sort,
        colors: AlphaSign::Colors::NAMES.keys.sort,
        positions: AlphaSign::Positions::NAMES.keys.sort,
        fonts: AlphaSign::CharSets::NAMES.keys.sort,
        dots_colors: AlphaSign::DotsColors::NAMES.keys
      }.to_json
    end

    get "/messages" do
      { messages: settings.sent_messages }.to_json
    end

    post "/messages" do
      body = json_body
      label = (body[:label] || "A").to_s
      text_file = build_text_file(body, label_override: label)
      packet = text_file.to_packet(type: body[:type] || Config.type, address: body[:address] || Config.address)
      result = send_or_report(packet, dry_run: truthy?(body[:dry_run]), label: label, meta: body.merge(label: label))
      result.to_json
    end

    delete "/messages/:label" do
      dry_run = truthy?(params[:dry_run])
      text_file = AlphaSign::TextFile.new("", label: params[:label])
      packet = text_file.to_packet(type: Config.type, address: Config.address)
      result = send_or_report(packet, dry_run: dry_run, label: params[:label])
      settings.sent_messages.delete(params[:label]) unless dry_run
      result.to_json
    end

    post "/priority" do
      body = json_body
      text_file = build_text_file(body, default_position: "middle", default_mode: "hold", priority_override: true)
      packet = text_file.to_packet(type: body[:type] || Config.type, address: body[:address] || Config.address)
      result = send_or_report(packet, dry_run: truthy?(body[:dry_run]), label: "0", meta: body.merge(label: "0"))
      result.to_json
    end

    delete "/priority" do
      dry_run = truthy?(params[:dry_run])
      text_file = AlphaSign::TextFile.new("", priority: true)
      packet = text_file.to_packet(type: Config.type, address: Config.address)
      result = send_or_report(packet, dry_run: dry_run, label: "0")
      settings.sent_messages.delete("0") unless dry_run
      result.to_json
    end

    post "/raw" do
      body = json_body
      command_code = body[:command_code]
      halt 400, { ok: false, error: "command_code is required" }.to_json if command_code.nil? || command_code.to_s.empty?

      packet = AlphaSign::Packet.new(
        "#{command_code}#{body[:data]}",
        type: body[:type] || Config.type,
        address: body[:address] || Config.address
      )
      result = send_or_report(packet, dry_run: truthy?(body[:dry_run]))
      result.to_json
    end

    # Displays an image as a Small Dots Picture. Unlike /messages, this
    # sends TWO packets: a Memory Configuration defining the label as a
    # Dots file (which - important - replaces the sign's ENTIRE file
    # layout, not just this label), then the actual pixel data. See
    # AlphaSign::DotsFile/MemoryConfig for the protocol-provenance caveat.
    post "/image" do
      body = json_body
      label = (body[:label] || "P").to_s
      width = required_positive_int(body, :width)
      height = required_positive_int(body, :height)
      pixels = body[:pixels].to_s
      expected_length = width * height
      if pixels.length != expected_length
        halt 400, { ok: false, error: "pixels must be exactly width*height characters (#{expected_length}), got #{pixels.length}" }.to_json
      end

      rows = pixels.chars.each_slice(width).map(&:join)
      dots = AlphaSign::DotsFile.new(rows, label: label)
      chip_fraction = dots.lit_chip_fraction

      if chip_fraction > 0.5 && !truthy?(body[:force])
        halt 422, {
          ok: false,
          error: format(
            "this image would light about %<pct>d%% of LED chips at once - XDF's manual warns against " \
            "sustaining more than 50%% to avoid thermal damage. Reduce brightness/coverage, or pass " \
            "force:true to send anyway.", pct: (chip_fraction * 100).round
          ),
          lit_chip_fraction: chip_fraction
        }.to_json
      end

      keep_text_labels = truthy?(body.fetch(:keep_text_labels, true))
      memory_config = AlphaSign::MemoryConfig.new
      if keep_text_labels
        settings.sent_messages.each do |existing_label, meta|
          next if existing_label == label || existing_label == "0" # "0" is the Priority Text File - not a real memory-config slot
          size = [estimate_text_size(meta), 256].max
          memory_config.text_file(existing_label, size: size)
        end
      end
      memory_config.dots_file(label, height: height, width: width, monochrome: truthy?(body[:monochrome]), locked: truthy?(body[:locked]))

      type = body[:type] || Config.type
      address = body[:address] || Config.address
      config_packet = memory_config.to_packet(type: type, address: address)
      dots_packet = dots.to_packet(type: type, address: address)

      if truthy?(body[:dry_run])
        halt 200, {
          ok: true, dry_run: true,
          memory_config_bytes_hex: config_packet.to_hex, dots_bytes_hex: dots_packet.to_hex,
          lit_fraction: dots.lit_fraction, lit_chip_fraction: chip_fraction
        }.to_json
      end

      begin
        settings.conn_mutex.synchronize do
          settings.connection.write(config_packet)
          # XDF blanks the display and defragments/reconfigures memory on
          # a Memory Config write - give it a moment before the picture
          # data arrives rather than risk it queuing mid-reconfiguration.
          sleep 1
          settings.connection.write(dots_packet)
        end
      rescue StandardError, LoadError => e
        # LoadError isn't a StandardError - see send_or_report's comment
        # on the same rescue clause for why it's caught here too.
        settings.last_error = e.message
        halt 502, { ok: false, error: e.message }.to_json
      end
      settings.last_error = nil

      # The memory config just replaced the sign's whole file layout, so
      # our tracked state needs to match: everything except the new image
      # is gone (or was explicitly re-included above, in which case it's
      # still real on the sign - just re-add it to keep GET /messages
      # accurate).
      preserved = keep_text_labels ? settings.sent_messages.reject { |l, _| l == label || l == "0" } : {}
      settings.sent_messages.clear
      settings.sent_messages.merge!(preserved)
      settings.sent_messages[label] = { type: "image", width: width, height: height, sent_at: Time.now.utc.iso8601 }

      {
        ok: true, label: label, lit_fraction: dots.lit_fraction, lit_chip_fraction: chip_fraction,
        memory_config_bytes_hex: config_packet.to_hex, dots_bytes_hex: dots_packet.to_hex
      }.to_json
    end
  end
end
