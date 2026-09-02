require "dotenv"
# Resolved against the repo root rather than the working directory: plain
# `require "dotenv/load"` only looks in Dir.pwd, so starting the service
# from anywhere else (a subdirectory, or a systemd unit with a different
# WorkingDirectory) would silently find nothing. Never overrides env vars
# that are already set, e.g. from a systemd EnvironmentFile.
Dotenv.load(File.expand_path("../.env", __dir__))

require "sinatra/base"
require "json"

require_relative "../lib/alpha_sign"
require_relative "config"
require_relative "layout"

module SerialApi
  # The device driver service: owns the serial port and exposes the Alpha
  # protocol as JSON HTTP. No authentication - meant to be reachable only
  # from 127.0.0.1 (see web_app/, which is the authenticated front door).
  #
  # File model (see docs/xdf-firmware-notes.md): TEXT files are what the
  # sign actually displays. STRING and DOTS PICTURE files are only ever
  # shown because a TEXT file calls them inline. Writing a string or a
  # picture on its own displays nothing - the call has to be in a message.
  class App < Sinatra::Base
    # The sign blanks and reorganises memory while processing a Memory
    # Configuration; give it a moment before the content writes land.
    RECONFIGURE_PAUSE = 1

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
      set :layout, Layout.new
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

      def packet_type
        @packet_type ||= Config.type
      end

      def packet_address
        @packet_address ||= Config.address
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

      def valid_label!(label)
        label = label.to_s
        halt 400, { ok: false, error: "label must be a single character, got #{label.inspect}" }.to_json unless label.length == 1
        label
      end

      # Writes the change that just went into the layout.
      #
      # If the layout still matches what the sign was last configured for,
      # only +packets+ (the thing that actually changed) is sent. If it
      # doesn't, a Memory Configuration goes first - which erases every
      # file - followed by a full re-send of all file contents, since
      # anything not re-sent would simply be gone.
      def write_layout_change(packets, dry_run:, extra: {})
        reconfiguring = settings.layout.needs_reconfiguration?
        config = reconfiguring ? settings.layout.memory_config : nil

        if reconfiguring
          packets = settings.layout.content_packets(type: packet_type, address: packet_address)
        end

        response = {
          ok: true,
          reconfigured: reconfiguring,
          memory_config_bytes_hex: config&.to_packet(type: packet_type, address: packet_address)&.to_hex,
          bytes_hex: packets.map(&:to_hex)
        }.merge(extra)

        if dry_run
          return response.merge(dry_run: true).to_json
        end

        begin
          settings.conn_mutex.synchronize do
            if config
              settings.connection.write(config.to_packet(type: packet_type, address: packet_address))
              sleep RECONFIGURE_PAUSE
            end
            packets.each { |packet| settings.connection.write(packet) }
          end
        rescue StandardError, LoadError => e
          # LoadError isn't a StandardError, but SerialConnection#open
          # deliberately raises it when the 'serialport' gem isn't
          # installed - that should surface as a normal API error, not a
          # 500.
          settings.last_error = e.message
          halt 502, { ok: false, error: e.message }.to_json
        end

        settings.last_error = nil
        settings.layout.mark_configured! if reconfiguring
        response.to_json
      end

      # For the packets that sit outside the file system entirely (the
      # Priority Text File, the raw escape hatch) - no layout involved.
      def send_standalone(packet, dry_run:)
        return { ok: true, dry_run: true, bytes_hex: packet.to_hex }.to_json if dry_run

        settings.conn_mutex.synchronize { settings.connection.write(packet) }
        settings.last_error = nil
        { ok: true, bytes_hex: packet.to_hex }.to_json
      rescue StandardError, LoadError => e
        settings.last_error = e.message
        halt 502, { ok: false, error: e.message }.to_json
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

    # Everything the sign is currently holding, by file type.
    get "/files" do
      settings.layout.to_h.to_json
    end

    # Text files - the only files the sign displays directly.
    get "/messages" do
      { messages: settings.layout.to_h[:text] }.to_json
    end

    post "/messages" do
      body = json_body
      label = valid_label!(body[:label] || "A")

      if truthy?(body[:priority])
        # The Priority Text File lives outside the file system - it has its
        # own fixed buffer, so it never takes part in memory configuration.
        speed_prefix = body[:speed] ? AlphaSign::Speeds.lookup(body[:speed]) : ""
        text_file = AlphaSign::TextFile.new(
          speed_prefix + AlphaSign::Runs.encode(body[:runs] || []),
          position: AlphaSign::Positions.lookup(body[:position] || "middle"),
          mode: AlphaSign::Modes.lookup(body[:mode] || "hold"),
          priority: true
        )
        return send_standalone(text_file.to_packet(type: packet_type, address: packet_address),
                               dry_run: truthy?(body[:dry_run]))
      end

      settings.layout.put_text(label, runs: body[:runs] || [], position: body[:position],
                                       mode: body[:mode], speed: body[:speed])
      packet = settings.layout.text_packet(label, type: packet_type, address: packet_address)
      write_layout_change([packet], dry_run: truthy?(body[:dry_run]), extra: { label: label })
    end

    delete "/messages/:label" do
      label = valid_label!(params[:label])
      dry_run = truthy?(params[:dry_run])
      settings.layout.delete(:text, label) unless dry_run
      packet = AlphaSign::TextFile.new("", label: label).to_packet(type: packet_type, address: packet_address)
      write_layout_change([packet], dry_run: dry_run, extra: { label: label })
    end

    # String files - reusable text a message can call inline. Rewriting one
    # is the cheap way to change part of a message: strings are double
    # buffered, so the update swaps in without blanking the display.
    post "/strings" do
      body = json_body
      label = valid_label!(body[:label] || "1")
      settings.layout.put_string(label, text: body[:text].to_s)
      packet = settings.layout.string_packet(label, type: packet_type, address: packet_address)
      write_layout_change([packet], dry_run: truthy?(body[:dry_run]), extra: { label: label })
    end

    delete "/strings/:label" do
      label = valid_label!(params[:label])
      dry_run = truthy?(params[:dry_run])
      settings.layout.delete(:string, label) unless dry_run
      packet = AlphaSign::StringFile.new("", label: label).to_packet(type: packet_type, address: packet_address)
      write_layout_change([packet], dry_run: dry_run, extra: { label: label })
    end

    # Dots Picture files. Note this only stores the picture - it appears on
    # the display when a message calls it (a {type: "image"} run).
    post "/image" do
      body = json_body
      label = valid_label!(body[:label] || "P")
      width = required_positive_int(body, :width)
      height = required_positive_int(body, :height)
      pixels = body[:pixels].to_s
      expected_length = width * height
      if pixels.length != expected_length
        halt 400, { ok: false, error: "pixels must be exactly width*height characters (#{expected_length}), got #{pixels.length}" }.to_json
      end

      settings.layout.put_dots(label, width: width, height: height, pixels: pixels,
                                      monochrome: truthy?(body[:monochrome]))
      dots = settings.layout.dots_file(label)
      chip_fraction = dots.lit_chip_fraction

      if chip_fraction > 0.5 && !truthy?(body[:force])
        settings.layout.delete(:dots, label)
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

      settings.layout.delete(:dots, label) if truthy?(body[:dry_run])
      packet = dots.to_packet(type: packet_type, address: packet_address)
      write_layout_change([packet], dry_run: truthy?(body[:dry_run]),
                                    extra: { label: label, lit_fraction: dots.lit_fraction,
                                             lit_chip_fraction: chip_fraction })
    end

    delete "/image/:label" do
      label = valid_label!(params[:label])
      dry_run = truthy?(params[:dry_run])
      settings.layout.delete(:dots, label) unless dry_run
      # Nothing to write for the file itself - it stops existing at the
      # next reconfiguration - so this is a layout-only change.
      write_layout_change([], dry_run: dry_run, extra: { label: label })
    end

    # The Priority Text File overrides everything else on the display. It
    # has its own fixed buffer outside the file system, so it never takes
    # part in memory configuration.
    post "/priority" do
      body = json_body
      speed_prefix = body[:speed] ? AlphaSign::Speeds.lookup(body[:speed]) : ""
      text_file = AlphaSign::TextFile.new(
        speed_prefix + AlphaSign::Runs.encode(body[:runs] || []),
        position: AlphaSign::Positions.lookup(body[:position] || "middle"),
        mode: AlphaSign::Modes.lookup(body[:mode] || "hold"),
        priority: true
      )
      send_standalone(text_file.to_packet(type: packet_type, address: packet_address),
                      dry_run: truthy?(body[:dry_run]))
    end

    delete "/priority" do
      text_file = AlphaSign::TextFile.new("", priority: true)
      send_standalone(text_file.to_packet(type: packet_type, address: packet_address),
                      dry_run: truthy?(params[:dry_run]))
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
      send_standalone(packet, dry_run: truthy?(body[:dry_run]))
    end
  end
end
