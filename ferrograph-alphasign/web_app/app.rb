require "dotenv"
# Resolved against the repo root rather than the working directory - see
# the matching comment in serial_api/app.rb for why.
Dotenv.load(File.expand_path("../.env", __dir__))

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
      begin
        BCrypt::Password.new(password_hash)
      rescue BCrypt::Errors::InvalidHash
        raise "WEB_APP_PASSWORD_HASH doesn't look like a valid bcrypt hash (got #{password_hash.length} " \
              "chars starting #{password_hash[0, 12].inspect}). A common cause: capturing " \
              "bin/hash_password's prompt text along with the hash, e.g. via a shell that doesn't " \
              "separate its stdout/stderr. Re-run bin/hash_password and paste back exactly one line " \
              "starting with $2a$ or $2b$."
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

      def timeout_query
        params[:timeout] ? "?timeout=#{URI.encode_www_form_component(params[:timeout])}" : ""
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

    get "/api/files" do
      proxy(:get, "/files")
    end

    post "/api/strings" do
      proxy(:post, "/strings", parsed_body)
    end

    delete "/api/strings/:label" do
      proxy(:delete, "/strings/#{valid_label!(params[:label])}#{dry_run_query}")
    end

    delete "/api/image/:label" do
      proxy(:delete, "/image/#{valid_label!(params[:label])}#{dry_run_query}")
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

    post "/api/image" do
      proxy(:post, "/image", parsed_body)
    end

    # Reading back from the sign. Diagnostic for now: these return the raw
    # reply bytes, because the request formats for reads come from Alpha's
    # protocol manual rather than XDF's own, so what the sign actually
    # answers is worth seeing before anything is built on top of it.
    get "/api/sign/:what" do
      what = params[:what]
      halt 400, { ok: false, error: "unknown read #{what.inspect}" }.to_json unless %w[memory_config dump].include?(what)
      proxy(:get, "/sign/#{what}#{timeout_query}")
    end

    get "/api/sign/:kind/:label" do
      kind = params[:kind]
      halt 400, { ok: false, error: "unknown file kind #{kind.inspect}" }.to_json unless %w[text string image].include?(kind)
      proxy(:get, "/sign/#{kind}/#{valid_label!(params[:label])}#{timeout_query}")
    end

    post "/api/read" do
      proxy(:post, "/read", parsed_body)
    end
  end
end
