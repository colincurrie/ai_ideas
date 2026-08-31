require "test_helper"
require "rack/test"
require_relative "../../serial_api/app"

module SerialApi
  # Stands in for AlphaSign::SerialConnection to deterministically exercise
  # error handling without depending on whether this machine happens to
  # have the 'serialport' gem or real hardware attached.
  class FailingConnection
    def initialize(error)
      @error = error
    end

    def write(_packet)
      raise @error
    end
  end

  class AppTest < Minitest::Test
    include Rack::Test::Methods

    def app
      App
    end

    def setup
      # Each test gets a clean slate for server-tracked message state.
      App.set :sent_messages, {}
      App.set :last_error, nil
    end

    def test_status_reports_configuration
      get "/status"
      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      assert_equal "none", body["parity"]
      assert_equal 8, body["data_bits"]
      assert_equal false, body["connected"]
    end

    def test_options_lists_names
      get "/options"
      body = JSON.parse(last_response.body)
      assert_includes body["modes"], "rotate"
      assert_includes body["colors"], "red"
      assert_includes body["positions"], "fill"
      assert_includes body["fonts"], "seven_high"
    end

    def test_send_message_dry_run_returns_expected_bytes
      post "/messages", {
        label: "A", position: "middle", mode: "hold", dry_run: true,
        runs: [{ text: "hi", color: "red" }]
      }.to_json, "CONTENT_TYPE" => "application/json"

      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      assert body["dry_run"]
      expected = AlphaSign::Packet.new("AA\x1B\x20b\x1C1hi").to_hex
      assert_equal expected, body["bytes_hex"]
    end

    def test_send_message_load_error_returns_clean_502_not_500
      # Regression test: SerialConnection#open raises LoadError (not a
      # StandardError, e.g. when the 'serialport' gem isn't installed),
      # which earlier slipped past a `rescue StandardError` and produced a
      # raw Sinatra 500 instead of a JSON error response.
      original = App.settings.connection
      App.set :connection, FailingConnection.new(LoadError.new("the 'serialport' gem is required"))

      post "/messages", { label: "A", runs: [{ text: "hi" }] }.to_json,
           "CONTENT_TYPE" => "application/json"

      assert_equal 502, last_response.status
      body = JSON.parse(last_response.body)
      assert_equal false, body["ok"]
      assert_match(/serialport/, body["error"])
    ensure
      App.set :connection, original
    end

    def test_send_message_dry_run_does_not_record_state
      post "/messages", { label: "A", dry_run: true, runs: [{ text: "hi" }] }.to_json,
           "CONTENT_TYPE" => "application/json"
      get "/messages"
      assert_empty JSON.parse(last_response.body)["messages"]
    end

    def test_unknown_color_returns_400
      post "/messages", { label: "A", dry_run: true, runs: [{ text: "hi", color: "bogus" }] }.to_json,
           "CONTENT_TYPE" => "application/json"
      assert_equal 400, last_response.status
      assert_match(/unknown color/, JSON.parse(last_response.body)["error"])
    end

    def test_clear_label_dry_run
      delete "/messages/A?dry_run=true"
      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      expected = AlphaSign::Packet.new("AA").to_hex
      assert_equal expected, body["bytes_hex"]
    end

    def test_raw_requires_command_code
      post "/raw", { dry_run: true }.to_json, "CONTENT_TYPE" => "application/json"
      assert_equal 400, last_response.status
    end

    def test_raw_dry_run
      post "/raw", { command_code: "E", data: "23", dry_run: true }.to_json,
           "CONTENT_TYPE" => "application/json"
      body = JSON.parse(last_response.body)
      expected = AlphaSign::Packet.new("E23").to_hex
      assert_equal expected, body["bytes_hex"]
    end
  end
end
