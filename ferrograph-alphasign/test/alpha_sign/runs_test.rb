require "test_helper"

module AlphaSign
  class RunsTest < Minitest::Test
    def test_plain_text_run
      assert_equal "hello", Runs.encode([{ text: "hello" }])
    end

    def test_color_and_font_emitted_once_per_run
      runs = [
        { text: "SALE ", color: "red", font: "seven_high_fancy" },
        { text: "50% OFF", color: "green", font: "large_fancy" }
      ]
      expected = "\x1C1\x1A5SALE \x1C2\x1A8" "50% OFF"
      assert_equal expected, Runs.encode(runs)
    end

    def test_repeated_color_is_not_re_emitted
      runs = [
        { text: "hello ", color: "red" },
        { text: "world", color: "red" }
      ]
      assert_equal "\x1C1hello world", Runs.encode(runs)
    end

    def test_color_change_mid_message_emits_new_code
      runs = [
        { text: "hello ", color: "red" },
        { text: "world", color: "green" }
      ]
      assert_equal "\x1C1hello \x1C2world", Runs.encode(runs)
    end

    def test_empty_text_run_is_skipped
      assert_equal "ab", Runs.encode([{ text: "a" }, { text: "" }, { text: "b" }])
    end

    def test_unknown_color_raises
      assert_raises(ArgumentError) { Runs.encode([{ text: "x", color: "nope" }]) }
    end

    def test_empty_runs_array
      assert_equal "", Runs.encode([])
    end
  end
end
