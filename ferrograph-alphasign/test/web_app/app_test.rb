require "bcrypt"

ENV["SESSION_SECRET"] ||= "a" * 64
ENV["WEB_APP_USERNAME"] ||= "admin"
ENV["WEB_APP_PASSWORD_HASH"] ||= BCrypt::Password.create("secret123").to_s
ENV["WEB_APP_SECURE_COOKIES"] ||= "false" # rack-test doesn't speak HTTPS

require "test_helper"
require "rack/test"
require_relative "../../web_app/app"

module WebApp
  # Stands in for the real serial-api over HTTP, so these tests never touch
  # the network or need serial-api running.
  class FakeSerialClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def get(path)
      @calls << [:get, path]
      [200, { ok: true, seen_path: path }]
    end

    def post(path, body)
      @calls << [:post, path, body]
      [200, { ok: true, seen_path: path, seen_body: body }]
    end

    def delete(path)
      @calls << [:delete, path]
      [200, { ok: true, seen_path: path }]
    end
  end

  class AppTest < Minitest::Test
    include Rack::Test::Methods

    def app
      App
    end

    def setup
      @fake_client = FakeSerialClient.new
      App.set :serial_client, @fake_client
      header "HOST", "localhost"
    end

    def login!
      post "/login", username: "admin", password: "secret123"
    end

    def test_root_redirects_to_login_when_logged_out
      get "/"
      assert_equal 302, last_response.status
      assert_match(%r{/login\z}, last_response.location)
    end

    def test_login_page_renders
      get "/login"
      assert_equal 200, last_response.status
      assert_match(/Sign in/, last_response.body)
    end

    def test_wrong_password_rerenders_with_error
      post "/login", username: "admin", password: "nope"
      assert_equal 200, last_response.status
      assert_match(/Invalid username or password/, last_response.body)
    end

    def test_correct_login_grants_access
      login!
      assert_equal 302, last_response.status
      get "/"
      assert_equal 200, last_response.status
    end

    def test_logout_revokes_access
      login!
      post "/logout"
      get "/"
      assert_equal 302, last_response.status
    end

    def test_api_status_requires_login
      get "/api/status"
      assert_equal 302, last_response.status
    end

    def test_api_status_proxies_to_serial_client
      login!
      get "/api/status"
      assert_equal 200, last_response.status
      assert_equal [[:get, "/status"]], @fake_client.calls
      assert_equal true, JSON.parse(last_response.body)["ok"]
    end

    def test_api_messages_post_forwards_parsed_body
      login!
      post "/api/messages", { label: "A", runs: [{ text: "hi" }] }.to_json,
           "CONTENT_TYPE" => "application/json"
      assert_equal 200, last_response.status
      call = @fake_client.calls.first
      assert_equal :post, call[0]
      assert_equal "/messages", call[1]
      assert_equal "A", call[2][:label]
    end

    def test_api_delete_message_validates_label
      login!
      delete "/api/messages/!!"
      assert_equal 400, last_response.status
      assert_empty @fake_client.calls
    end

    def test_api_delete_message_forwards_dry_run_query
      login!
      delete "/api/messages/A?dry_run=true"
      assert_equal [[:delete, "/messages/A?dry_run=true"]], @fake_client.calls
    end
  end
end
