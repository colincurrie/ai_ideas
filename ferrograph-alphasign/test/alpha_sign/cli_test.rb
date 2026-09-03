require "test_helper"
require "open3"
require "rbconfig"

module AlphaSign
  # Runs the CLI as a subprocess: these are about what a person at a
  # terminal sees, including exit status and stderr, which is hard to
  # assert on any other way.
  class CliTest < Minitest::Test
    ROOT = File.expand_path("../..", __dir__)

    def run_cli(*args)
      Open3.capture3(RbConfig.ruby, "-I", File.join(ROOT, "lib"), File.join(ROOT, "bin", "alphasign"), *args)
    end

    # Regression: `read`, `probe` and `loopback` built a SerialConnection
    # directly instead of going through the check `send` used, so leaving
    # --device off produced a bare "wrong argument type (TypeError)" from
    # inside the serialport gem - a stack trace that says nothing about
    # the missing argument.
    def test_every_port_command_asks_for_a_device_rather_than_crashing
      [%w[send hello], %w[clear], %w[read config], %w[probe], %w[loopback]].each do |args|
        _out, err, status = run_cli(*args)
        refute_equal 0, status.exitstatus, "#{args.first} should fail without --device"
        assert_match(/--device is required/, err, "#{args.first} should say what's missing")
        refute_match(/TypeError|serialport\.rb/, err, "#{args.first} leaked a gem stack trace")
      end
    end

    def test_the_device_error_suggests_how_to_find_one
      _out, err, = run_cli("probe")
      assert_match(%r{/dev/tty}, err)
      assert_match(/ls /, err, "tells you how to find the device name")
    end

    # An empty --device is the same mistake as none at all (e.g. an unset
    # shell variable expanding to nothing).
    def test_an_empty_device_is_rejected_too
      _out, err, status = run_cli("probe", "--device", "")
      refute_equal 0, status.exitstatus
      assert_match(/--device is required/, err)
    end

    def test_dry_run_needs_no_device
      out, _err, status = run_cli("send", "--dry-run", "hello")
      assert_equal 0, status.exitstatus
      assert_match(/00 00 00 00 00 01/, out + _err)
    end

    def test_help_lists_the_diagnostic_commands
      out, = run_cli("--help")
      assert_match(/alphasign probe/, out)
      assert_match(/alphasign loopback/, out)
    end
  end
end
