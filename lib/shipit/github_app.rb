module Shipit
  class GitHubApp
    DOMAIN = 'github.com'.freeze
    AuthenticationFailed = Class.new(StandardError)

    attr_reader :oauth_teams, :domain, :bot_login

    def initialize(config)
      @config = (config || {}).with_indifferent_access
      @domain = @config[:domain] || DOMAIN
      @webhook_secret = @config[:webhook_secret].presence
      @bot_login = @config[:bot_login]

      oauth = (@config[:oauth] || {}).with_indifferent_access
      @oauth_id = oauth[:id]
      @oauth_secret = oauth[:secret]
      @oauth_teams = Array.wrap(oauth[:teams] || oauth[:teams])
    end

    def login
      raise NotImplementedError, 'Handle App login / user'
    end

    def api
      client = Thread.current[:github_client]
      if !client || client.access_token != token
        client = Thread.current[:github_client] = new_client(access_token: token)
      end
      client
    end

    def verify_webhook_signature(signature, message)
      return true unless webhook_secret

      algorithm, signature = signature.split("=", 2)
      return false unless algorithm == 'sha1'

      SecureCompare.secure_compare(signature, OpenSSL::HMAC.hexdigest(algorithm, webhook_secret, message))
    end

    def token
      return 't0kEn' if Rails.env.test? # TODO: figure out something cleaner
      return unless private_key && app_id && installation_id

      Rails.cache.fetch('github:integration:token', expires_in: 50.minutes, race_condition_ttl: 10.minutes) do
        token = new_client(bearer_token: authentication_payload).create_app_installation_access_token(
          installation_id,
          accept: 'application/vnd.github.machine-man-preview+json',
        ).token
        raise AuthenticationFailed if token.blank?
        token
      end
    end

    def oauth?
      oauth_id.present? && oauth_secret.present?
    end

    def oauth_config
      options = {}
      if enterprise?
        options = {
          site: api_endpoint,
          authorize_url: url('/login/oauth/authorize'),
          token_url: url('/login/oauth/access_token'),
        }
      end

      [
        oauth_id,
        oauth_secret,
        client_options: options,
      ]
    end

    def url(*path)
      @url ||= "https://#{domain}".freeze
      path.empty? ? @url : File.join(@url, *path.map(&:to_s))
    end

    def api_endpoint
      url('/api/v3/') if enterprise?
    end

    def enterprise?
      domain != DOMAIN
    end

    def new_client(options = {})
      client = Octokit::Client.new(options.reverse_merge(api_endpoint: api_endpoint))
      client.middleware = Shipit.new_faraday_stack
      client
    end

    private

    attr_reader :webhook_secret, :oauth_id, :oauth_secret

    def app_id
      @app_id ||= @config.fetch(:app_id)
    end

    def installation_id
      @installation_id ||= @config.fetch(:installation_id)
    end

    def private_key
      @private_key ||= @config.fetch(:private_key)
    end

    def authentication_payload
      payload = {
        iat: Time.now.to_i,
        exp: 10.minutes.from_now.to_i,
        iss: app_id,
      }
      key = OpenSSL::PKey::RSA.new(private_key)
      JWT.encode(payload, key, 'RS256')
    end
  end
end
