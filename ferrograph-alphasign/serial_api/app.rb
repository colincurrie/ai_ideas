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
        fonts: AlphaSign::CharSets::NAMES.keys.sort
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
  end
end
