require "test_helper"
require "tmpdir"
require "fileutils"
require_relative "../../serial_api/layout_store"

module SerialApi
  class LayoutStoreTest < Minitest::Test
    def setup
      @dir = Dir.mktmpdir("layout-store")
      @path = File.join(@dir, "layout.json")
      @store = LayoutStore.new(@path)
    end

    def teardown
      FileUtils.remove_entry(@dir) if File.exist?(@dir)
    end

    def populated
      layout = Layout.new
      layout.put_text("A", runs: [{ text: "HI", color: "red" }], position: "middle", mode: "hold")
      layout.put_string("1", text: "WORLD")
      layout.put_dots("P", width: 2, height: 2, pixels: "1230")
      layout.mark_configured!
      layout
    end

    def test_round_trips_every_file_type
      @store.save(populated)
      restored = LayoutStore.new(@path).load

      assert_equal [{ text: "HI", color: "red" }], restored.text["A"].runs
      assert_equal "middle", restored.text["A"].position
      assert_equal "WORLD", restored.strings["1"].text
      assert_equal "1230", restored.dots["P"].pixels
      assert_equal 2, restored.dots["P"].height
    end

    # The pixels are the only copy - nothing can read them back off the
    # sign - so a full-size picture has to survive intact.
    def test_a_full_size_picture_survives_intact
      pixels = (0...(135 * 16)).map { |i| (i % 4).to_s }.join
      layout = Layout.new
      layout.put_dots("P", width: 135, height: 16, pixels: pixels)
      @store.save(layout)

      assert_equal pixels, LayoutStore.new(@path).load.dots["P"].pixels
    end

    def test_restores_the_configuration_signature_so_a_restart_does_not_blank_the_display
      @store.save(populated)
      restored = LayoutStore.new(@path).load
      refute restored.needs_reconfiguration?
    end

    def test_forgetting_the_configuration_forces_a_resend
      layout = populated
      refute layout.needs_reconfiguration?
      layout.forget_configuration!
      assert layout.needs_reconfiguration?
    end

    def test_loading_with_no_file_yet_gives_an_empty_layout
      assert LayoutStore.new(@path).load.empty?
    end

    # A corrupt state file must not stop the service booting: an empty
    # layout costs one reconfiguration, a crash costs the display.
    def test_a_corrupt_file_is_reported_and_stepped_over
      File.write(@path, "{ this is not json")
      store = LayoutStore.new(@path)
      layout = capture_io { @loaded = store.load }.then { @loaded }

      assert layout.empty?
      assert_match(/couldn't read/, store.last_error)
    end

    def test_a_file_that_is_valid_json_but_the_wrong_shape_is_also_survivable
      File.write(@path, JSON.generate(text: "not a hash of files"))
      store = LayoutStore.new(@path)
      capture_io { @loaded = store.load }
      assert @loaded.empty?
      refute_nil store.last_error
    end

    # Renaming into place means a save is never seen half-written.
    def test_saving_leaves_no_temporary_files_behind
      @store.save(populated)
      assert_equal ["layout.json"], Dir.children(@dir)
    end

    def test_an_unwritable_location_is_reported_rather_than_raised
      # A file where the store wants a directory: mkdir_p fails with ENOTDIR.
      blocker = File.join(@dir, "blocked")
      File.write(blocker, "in the way")
      store = LayoutStore.new(File.join(blocker, "layout.json"))
      capture_io { @saved = store.save(populated) }
      refute @saved
      assert_match(/couldn't write/, store.last_error)
      assert_equal "in the way", File.read(blocker), "and nothing was trampled"
    end

    # Setting the path to empty turns persistence off - the old behaviour,
    # for anyone who wants it.
    def test_persistence_can_be_switched_off
      store = LayoutStore.new(nil)
      refute store.enabled?
      assert store.load.empty?
      assert_nil store.save(populated)
      assert_empty Dir.children(@dir)
    end

    def test_reports_when_the_state_was_saved
      @store.save(populated)
      store = LayoutStore.new(@path)
      store.load
      refute_nil store.loaded_at, "so /status can say how old the record is"
    end
  end
end
