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

  # Records what was written instead of touching hardware, so tests can
  # assert on the packets a request actually produces.
  class RecordingConnection
    attr_reader :packets

    def initialize
      @packets = []
    end

    def write(packet)
      @packets << packet.to_s
    end

    def connected?
      true
    end
  end

  class AppTest < Minitest::Test
    include Rack::Test::Methods

    def app
      App
    end

    def setup
      App.set :layout, Layout.new
      App.set :last_error, nil
      @recorder = RecordingConnection.new
      App.set :connection, @recorder
      # Keep the reconfiguration pause out of the test suite's runtime -
      # it's a real hardware settling delay, not behaviour under test.
      if App::RECONFIGURE_PAUSE != 0
        App.send(:remove_const, :RECONFIGURE_PAUSE)
        App.const_set(:RECONFIGURE_PAUSE, 0)
      end
    end

    def json_post(path, payload)
      post path, payload.to_json, "CONTENT_TYPE" => "application/json"
      JSON.parse(last_response.body)
    end

    def test_status_reports_configuration
      get "/status"
      assert_equal 200, last_response.status
      body = JSON.parse(last_response.body)
      assert_equal "none", body["parity"]
      assert_equal 8, body["data_bits"]
    end

    def test_options_lists_names
      get "/options"
      body = JSON.parse(last_response.body)
      assert_includes body["modes"], "rotate"
      assert_includes body["colors"], "red"
      assert_includes body["positions"], "fill"
      assert_includes body["fonts"], "seven_high"
      assert_includes body["dots_colors"], "red"
    end

    # --- text messages ---

    def test_send_message_dry_run_returns_expected_bytes
      body = json_post("/messages", label: "A", position: "middle", mode: "hold", dry_run: true,
                                    runs: [{ text: "hi", color: "red" }])
      assert_equal 200, last_response.status
      assert body["dry_run"]
      expected = AlphaSign::Packet.new("AA\x1B\x20b\x1C1hi").to_hex
      assert_equal [expected], body["bytes_hex"]
    end

    # The whole point of the layout logic: a plain text message must not
    # trigger a memory configuration. XDF's default layout already provides
    # text files, and reconfiguring would blank the display for nothing.
    def test_text_only_never_reconfigures_memory
      body = json_post("/messages", label: "A", runs: [{ text: "hi" }])
      assert_equal 200, last_response.status
      refute body["reconfigured"], "a text-only message should not reconfigure memory"
      assert_nil body["memory_config_bytes_hex"]
      assert_equal 1, @recorder.packets.size
    end

    def test_send_message_load_error_returns_clean_502_not_500
      # LoadError isn't a StandardError (SerialConnection#open raises it
      # when the serialport gem is missing) - it must still surface as a
      # normal API error rather than a raw 500.
      App.set :connection, FailingConnection.new(LoadError.new("the 'serialport' gem is required"))
      body = json_post("/messages", label: "A", runs: [{ text: "hi" }])
      assert_equal 502, last_response.status
      assert_equal false, body["ok"]
      assert_match(/serialport/, body["error"])
    end

    def test_unknown_color_returns_400
      json_post("/messages", label: "A", dry_run: true, runs: [{ text: "hi", color: "bogus" }])
      assert_equal 400, last_response.status
      assert_match(/unknown color/, JSON.parse(last_response.body)["error"])
    end

    # --- strings ---

    def test_string_write_produces_a_write_string_packet
      body = json_post("/strings", label: "1", text: "HELLO", dry_run: true)
      assert_equal 200, last_response.status
      assert_includes body["bytes_hex"].join, AlphaSign::Packet.new("G1HELLO").to_hex
    end

    def test_first_string_forces_one_reconfiguration_then_no_more
      first = json_post("/strings", label: "1", text: "HELLO")
      assert first["reconfigured"], "defining the first string needs a memory configuration"
      refute_nil first["memory_config_bytes_hex"]

      second = json_post("/strings", label: "1", text: "WORLD")
      refute second["reconfigured"], "rewriting a string's contents must not reconfigure memory"
    end

    # --- images ---

    def test_image_dry_run_returns_expected_dots_bytes
      body = json_post("/image", label: "P", width: 3, height: 2, pixels: "123000", dry_run: true)
      assert_equal 200, last_response.status
      assert_includes body["bytes_hex"].join, AlphaSign::Packet.new("IP0203123\r000\r").to_hex
      assert_in_delta 0.5, body["lit_fraction"]
    end

    def test_image_dry_run_does_not_record_state
      json_post("/image", label: "P", width: 1, height: 1, pixels: "1", dry_run: true)
      get "/files"
      assert_empty JSON.parse(last_response.body)["dots"]
    end

    # The bug this architecture exists to prevent: sending an image used to
    # reconfigure memory (erasing every text file) and then write only the
    # picture, so the sign had nothing left to display and went blank.
    def test_sending_an_image_re_sends_the_text_files_it_erased
      json_post("/messages", label: "A", runs: [{ text: "HELLO" }])
      @recorder.packets.clear

      body = json_post("/image", label: "P", width: 2, height: 1, pixels: "10")
      assert body["reconfigured"]

      written = @recorder.packets.join
      assert_includes written, "IP0102", "the picture data should be written"
      assert_includes written, "AA", "the text file must be re-sent after the configuration erased it"
      assert_equal 3, @recorder.packets.size, "expected memory config + text file + picture"
    end

    def test_image_requires_width_and_height
      json_post("/image", label: "P", pixels: "1")
      assert_equal 400, last_response.status
    end

    def test_image_rejects_mismatched_pixel_count
      json_post("/image", label: "P", width: 2, height: 2, pixels: "11", dry_run: true)
      assert_equal 400, last_response.status
      assert_match(/width\*height/, JSON.parse(last_response.body)["error"])
    end

    def test_image_rejects_invalid_pixel_character_as_400_not_502
      # ArgumentError from bad pixel data must reach the global 400
      # handler, not be swallowed by the write-failure rescue as a 502.
      json_post("/image", label: "P", width: 2, height: 1, pixels: "9x", dry_run: true)
      assert_equal 400, last_response.status
      assert_match(/unknown dots color/, JSON.parse(last_response.body)["error"])
    end

    def test_image_blocks_over_50_percent_chip_load_without_force
      body = json_post("/image", label: "P", width: 2, height: 1, pixels: "33", dry_run: true) # all yellow
      assert_equal 422, last_response.status
      assert_in_delta 1.0, body["lit_chip_fraction"]
      assert_match(/50/, body["error"])
    end

    def test_blocked_image_is_not_left_in_the_layout
      json_post("/image", label: "P", width: 2, height: 1, pixels: "33")
      assert_equal 422, last_response.status
      get "/files"
      assert_empty JSON.parse(last_response.body)["dots"],
                   "an image rejected on safety grounds should not linger in the layout"
    end

    def test_image_force_bypasses_chip_load_check
      json_post("/image", label: "P", width: 2, height: 1, pixels: "33", dry_run: true, force: true)
      assert_equal 200, last_response.status
    end

    # --- references between files ---

    def test_message_can_call_a_string_and_an_image
      body = json_post("/messages", label: "A", dry_run: true, runs: [
                         { text: "NOW " },
                         { type: "image", label: "P" },
                         { type: "string", label: "1" }
                       ])
      assert_equal 200, last_response.status
      expected = AlphaSign::Packet.new("AA\x1B\x30oNOW \x14P\x101").to_hex
      assert_equal [expected], body["bytes_hex"]
    end

    def test_reference_run_rejects_a_multi_character_label
      json_post("/messages", label: "A", dry_run: true, runs: [{ type: "image", label: "PP" }])
      assert_equal 400, last_response.status
      assert_match(/single-character file label/, JSON.parse(last_response.body)["error"])
    end

    # --- other ---

    def test_priority_message_does_not_touch_the_file_system
      body = json_post("/priority", runs: [{ text: "URGENT" }], dry_run: true)
      assert_equal 200, last_response.status
      assert_match(/^00 00 00 00 00 01/, body["bytes_hex"])
      get "/files"
      assert_empty JSON.parse(last_response.body)["text"]
    end

    def test_raw_requires_command_code
      json_post("/raw", dry_run: true)
      assert_equal 400, last_response.status
    end

    def test_raw_dry_run
      body = json_post("/raw", command_code: "E", data: "23", dry_run: true)
      assert_equal AlphaSign::Packet.new("E23").to_hex, body["bytes_hex"]
    end
  end
end
