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

  # Stands in for a working connection - succeeds without touching real
  # hardware, so tests can exercise the "send actually happened" code path
  # (state tracking, etc.) deterministically.
  class NoopConnection
    def write(_packet); end
  end

  class AppTest < Minitest::Test
    include Rack::Test::Methods

    def app
      App
    end

    def setup
      # Each test gets a clean slate for server-tracked message state.
      #
      # Important: this MUST be `.clear`, not `App.set :sent_messages, {}`.
      # Sinatra gives Hash-valued settings special setter semantics (see
      # Sinatra::Base.set, the `when Hash` branch): after the first `set`
      # with a Hash value, later `set` calls merge the new value onto the
      # *original* hash object rather than replacing it. Since routes
      # mutate that same object in place (settings.sent_messages[x] = y),
      # re-`set`ting to {} here would silently no-op (merging {} changes
      # nothing) and state would leak across tests.
      App.settings.sent_messages.clear
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

    def test_options_includes_dots_colors
      get "/options"
      assert_includes JSON.parse(last_response.body)["dots_colors"], "red"
    end

    def test_image_dry_run_returns_expected_bytes
      post "/image", { label: "P", width: 3, height: 2, pixels: "123000", dry_run: true }.to_json,
           "CONTENT_TYPE" => "application/json"

      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      expected_dots = AlphaSign::Packet.new("IP0203123_0D000_0D").to_hex
      expected_config = AlphaSign::Packet.new("E$PDU02032000").to_hex
      assert_equal expected_dots, body["dots_bytes_hex"]
      assert_equal expected_config, body["memory_config_bytes_hex"]
      assert_in_delta 0.5, body["lit_fraction"]
    end

    def test_image_dry_run_does_not_record_state
      post "/image", { label: "P", width: 1, height: 1, pixels: "1", dry_run: true }.to_json,
           "CONTENT_TYPE" => "application/json"
      get "/messages"
      assert_empty JSON.parse(last_response.body)["messages"]
    end

    def test_image_requires_width_and_height
      post "/image", { label: "P", pixels: "1" }.to_json, "CONTENT_TYPE" => "application/json"
      assert_equal 400, last_response.status
    end

    def test_image_rejects_mismatched_pixel_count
      post "/image", { label: "P", width: 2, height: 2, pixels: "11", dry_run: true }.to_json,
           "CONTENT_TYPE" => "application/json"
      assert_equal 400, last_response.status
      assert_match(/width\*height/, JSON.parse(last_response.body)["error"])
    end

    def test_image_rejects_invalid_pixel_character_as_400_not_502
      # Regression guard: ArgumentError from bad pixel data (DotsColors
      # rejecting an out-of-range digit) must hit the global 400 handler,
      # not get caught by the write-failure rescue further down the route
      # and misreported as a 502.
      post "/image", { label: "P", width: 2, height: 1, pixels: "9x", dry_run: true }.to_json,
           "CONTENT_TYPE" => "application/json"
      assert_equal 400, last_response.status
      assert_match(/unknown dots color/, JSON.parse(last_response.body)["error"])
    end

    def test_image_blocks_over_50_percent_chip_load_without_force
      post "/image", { label: "P", width: 2, height: 1, pixels: "33", dry_run: true }.to_json,
           "CONTENT_TYPE" => "application/json" # all yellow = 100% chip load
      assert_equal 422, last_response.status
      body = JSON.parse(last_response.body)
      assert_in_delta 1.0, body["lit_chip_fraction"]
      assert_match(/50/, body["error"])
    end

    def test_image_force_bypasses_chip_load_check
      post "/image", { label: "P", width: 2, height: 1, pixels: "33", dry_run: true, force: true }.to_json,
           "CONTENT_TYPE" => "application/json"
      assert_equal 200, last_response.status
    end

    def test_image_real_send_preserves_and_clears_labels_correctly
      original = App.settings.connection
      App.set :connection, NoopConnection.new

      post "/messages", { label: "A", runs: [{ text: "hi" }] }.to_json, "CONTENT_TYPE" => "application/json"
      assert_equal 200, last_response.status

      post "/image", { label: "P", width: 1, height: 1, pixels: "1", keep_text_labels: true }.to_json,
           "CONTENT_TYPE" => "application/json"
      assert_equal 200, last_response.status

      get "/messages"
      messages = JSON.parse(last_response.body)["messages"]
      assert_includes messages.keys, "A", "text label should be preserved when keep_text_labels is true"
      assert_includes messages.keys, "P"
    ensure
      App.set :connection, original
    end

    def test_image_real_send_without_keep_text_labels_drops_others
      original = App.settings.connection
      App.set :connection, NoopConnection.new

      post "/messages", { label: "A", runs: [{ text: "hi" }] }.to_json, "CONTENT_TYPE" => "application/json"
      post "/image", { label: "P", width: 1, height: 1, pixels: "1", keep_text_labels: false }.to_json,
           "CONTENT_TYPE" => "application/json"

      get "/messages"
      messages = JSON.parse(last_response.body)["messages"]
      refute_includes messages.keys, "A"
      assert_includes messages.keys, "P"
    ensure
      App.set :connection, original
    end
  end
end
