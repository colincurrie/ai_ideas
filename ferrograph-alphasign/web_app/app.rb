require "sinatra/base"
require "bcrypt"
require "json"
require "uri"

require_relative "serial_api_client"

module WebApp
  # The authenticated front door: owns login/sessions and the compose UI,
  # and proxies API calls through to serial-api (which has no auth of its
  # own and should only ever be reachable from this process).
  class App < Sinatra::Base
    set :views, File.join(__dir__, "views")
    set :public_folder, File.join(__dir__, "public")

    configure do
      set :show_exceptions, false
      set :raise_errors, false

      set :sessions, {
        httponly: true,
        same_site: :lax,
        # Only relax this to "false" for local testing over plain HTTP -
        # once served over Tailscale HTTPS (see README), leave it true so
        # the session cookie is never sent over an unencrypted connection.
        secure: ENV.fetch("WEB_APP_SECURE_COOKIES", "true") == "true",
        expire_after: 60 * 60 * 24 * 7 # 1 week
      }

      session_secret = ENV["SESSION_SECRET"]
      if session_secret.nil? || session_secret.empty?
        raise "SESSION_SECRET env var is required. Generate one with: " \
              "ruby -rsecurerandom -e 'puts SecureRandom.hex(64)'"
      end
      set :session_secret, session_secret

      set :username, ENV.fetch("WEB_APP_USERNAME", "admin")

      password_hash = ENV["WEB_APP_PASSWORD_HASH"]
      if password_hash.nil? || password_hash.empty?
        raise "WEB_APP_PASSWORD_HASH env var is required. Generate one with: bin/hash_password"
      end
      set :password_hash, password_hash

      # Unlike serial-api, this service IS meant to be reached over the
      # network (via Tailscale) - so Host header validation is worth
      # keeping. Add your Tailscale hostname via WEB_APP_ALLOWED_HOSTS
      # (comma separated) once you're not just testing on localhost.
      set :host_authorization, permitted_hosts: ENV.fetch("WEB_APP_ALLOWED_HOSTS", "localhost,127.0.0.1").split(",").map(&:strip)

      set :serial_client, SerialApiClient.new(ENV.fetch("SERIAL_API_URL", "http://127.0.0.1:4568"))
    end

    helpers do
      def logged_in?
        !!session[:user]
      end

      def parsed_body
        raw = request.body.read
        return {} if raw.nil? || raw.empty?

        JSON.parse(raw, symbolize_names: true)
      rescue JSON::ParserError
        halt 400, { ok: false, error: "invalid JSON" }.to_json
      end

      # Forwards to serial-api and mirrors its status code/JSON body back.
      def proxy(method, path, body = nil)
        code, json = settings.serial_client.public_send(method, path, *[body].compact)
        content_type :json
        status code
        json.to_json
      end

      def valid_label!(label)
        halt 400, { ok: false, error: "invalid label #{label.inspect}" }.to_json unless label =~ /\A[A-Za-z0-9]{1,2}\z/
        label
      end

      def dry_run_query
        params[:dry_run] ? "?dry_run=#{URI.encode_www_form_component(params[:dry_run])}" : ""
      end
    end

    before do
      redirect "/login" unless request.path_info == "/login" || logged_in?
    end

    get "/login" do
      redirect "/" if logged_in?
      erb :login, locals: { error: nil }
    end

    post "/login" do
      username = params[:username].to_s
      password = params[:password].to_s
      valid = username == settings.username && BCrypt::Password.new(settings.password_hash) == password

      if valid
        session[:user] = username
        redirect "/"
      else
        erb :login, locals: { error: "Invalid username or password" }
      end
    end

    post "/logout" do
      session.clear
      redirect "/login"
    end

    get "/" do
      erb :index
    end

    get "/api/status" do
      proxy(:get, "/status")
    end

    get "/api/options" do
      proxy(:get, "/options")
    end

    get "/api/messages" do
      proxy(:get, "/messages")
    end

    post "/api/messages" do
      proxy(:post, "/messages", parsed_body)
    end

    delete "/api/messages/:label" do
      proxy(:delete, "/messages/#{valid_label!(params[:label])}#{dry_run_query}")
    end

    post "/api/priority" do
      proxy(:post, "/priority", parsed_body)
    end

    delete "/api/priority" do
      proxy(:delete, "/priority#{dry_run_query}")
    end

    post "/api/raw" do
      proxy(:post, "/raw", parsed_body)
    end
  end
end
