require 'fog/aws'
require 'dragonfly'
require 'cgi'
require 'securerandom'
require 'aws-sdk'

Dragonfly::App.register_datastore(:s3){ Dragonfly::S3DataStore }

module LoggerHelper

  DEFAULT_GELF_API_PATH = "gelf"
  PARAMETER_HOST = "Dragonfly"

  SESSION_ID =  ([*('A'..'Z'),*('0'..'9')]-%w(0 1 I O)).sample(5).join
  
  def logger_request(requestApiPath, requestParameters)
    require 'net/http'
    require 'uri'
    require 'json'

    uri = URI.parse("http://logger.omnivirt.com:12202/")
    request_uri = "/#{requestApiPath}"

    header = {'Content-Type' => 'application/json'}

    # Create the HTTP objects
    http = Net::HTTP.new(uri.host, uri.port)
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE

    request = Net::HTTP::Post.new(request_uri, header)
    request.body = requestParameters.to_json

    # # Send the request
    response = http.request(request)
  end

  def logger_log(shortMessage, fullMessage, isIncludeUserPrefix)

    userIdString = (((defined? current_user) == nil) || current_user.nil?) ? "0" : current_user.id.to_s
    userPrefix = userIdString + "-" + SESSION_ID

    shortMessage = isIncludeUserPrefix ? userPrefix + " " + shortMessage : shortMessage

    requestParameters = {
			"short_message" => shortMessage,
			"sender" => PARAMETER_HOST,
			"full_message" => fullMessage
    }
    logger_request(DEFAULT_GELF_API_PATH, requestParameters)
  end

end

module Dragonfly
  class S3DataStore

    # Exceptions
    class NotConfigured < RuntimeError; end

    REGIONS = {
      'us-east-1' => 's3.amazonaws.com',  #default
      'us-west-1' => 's3-us-west-1.amazonaws.com',
      'us-west-2' => 's3-us-west-2.amazonaws.com',
      'ap-northeast-1' => 's3-ap-northeast-1.amazonaws.com',
      'ap-southeast-1' => 's3-ap-southeast-1.amazonaws.com',
      'ap-southeast-2' => 's3-ap-southeast-2.amazonaws.com',
      'eu-west-1' => 's3-eu-west-1.amazonaws.com',
      'eu-central-1' => 's3-eu-central-1.amazonaws.com',
      'sa-east-1' => 's3-sa-east-1.amazonaws.com'
    }

    SUBDOMAIN_PATTERN = /^[a-z0-9][a-z0-9.-]+[a-z0-9]$/

    def initialize(opts={})
      @bucket_name = opts[:bucket_name]
      @access_key_id = opts[:access_key_id]
      @secret_access_key = opts[:secret_access_key]
      @region = opts[:region]
      @storage_headers = opts[:storage_headers] || {'x-amz-acl' => 'public-read'}
      @url_scheme = opts[:url_scheme] || 'http'
      @url_host = opts[:url_host]
      @use_iam_profile = opts[:use_iam_profile]
      @root_path = opts[:root_path]
      @fog_storage_options = opts[:fog_storage_options] || {}
      @retry_count = 0
    end

    attr_accessor :bucket_name, :access_key_id, :secret_access_key, :region, :storage_headers, :url_scheme, :url_host, :use_iam_profile, :root_path, :fog_storage_options

    def write(content, opts={})
      ensure_configured
      ensure_bucket_initialized

      headers = {'Content-Type' => content.mime_type}
      headers.merge!(opts[:headers]) if opts[:headers]
      uid = opts[:path] || generate_uid(content.name || 'file')

      rescuing_all_errors do
        s3 = Aws::S3::Resource.new(
          :access_key_id => @access_key_id,
          :secret_access_key => @secret_access_key,
          :region => 'us-east-1'
        )
        s3.bucket(bucket_name).object(full_path(uid)).upload_file(content.file.path, {:metadata => full_storage_headers(headers, content.meta)})
        #content.file do |f|
        #  storage.put_object(bucket_name, full_path(uid), f, full_storage_headers(headers, content.meta))
        #end
      end
      
      uid
    end

    def read(uid)
      ensure_configured
      response = rescuing_socket_errors{ storage.get_object(bucket_name, full_path(uid)) }
      [response.body, headers_to_meta(response.headers)]
    rescue Excon::Errors::NotFound => e
      nil
    end

    def destroy(uid)
      rescuing_socket_errors{ storage.delete_object(bucket_name, full_path(uid)) }
    rescue Excon::Errors::NotFound, Excon::Errors::Conflict => e
      Dragonfly.warn("#{self.class.name} destroy error: #{e}")
    end

    def url_for(uid, opts={})
      if expires = opts[:expires]
        storage.get_object_https_url(bucket_name, full_path(uid), expires, {:query => opts[:query]})
      else
        scheme = opts[:scheme] || url_scheme
        host   = opts[:host]   || url_host || (
          bucket_name =~ SUBDOMAIN_PATTERN ? "#{bucket_name}.s3.amazonaws.com" : "s3.amazonaws.com/#{bucket_name}"
        )
        "#{scheme}://#{host}/#{full_path(uid)}"
      end
    end

    def domain
      REGIONS[get_region]
    end

    def storage
      @storage ||= begin
        storage = Fog::Storage.new(fog_storage_options.merge({
          :provider => 'AWS',
          :aws_access_key_id => access_key_id,
          :aws_secret_access_key => secret_access_key,
          :region => region,
          :use_iam_profile => use_iam_profile
        }).reject {|name, option| option.nil?})
        storage.sync_clock
        storage
      end
    end

    def bucket_exists?
      rescuing_socket_errors{ storage.get_bucket_location(bucket_name) }
      true
    rescue Excon::Errors::NotFound => e
      false
    end

    private

    def ensure_configured
      unless @configured
        if use_iam_profile
          raise NotConfigured, "You need to configure #{self.class.name} with bucket_name" if bucket_name.nil?
        else
          [:bucket_name, :access_key_id, :secret_access_key].each do |attr|
            raise NotConfigured, "You need to configure #{self.class.name} with #{attr}" if send(attr).nil?
          end
        end
        @configured = true
      end
    end

    def ensure_bucket_initialized
      unless @bucket_initialized
        rescuing_socket_errors{ storage.put_bucket(bucket_name, 'LocationConstraint' => region) } unless bucket_exists?
        @bucket_initialized = true
      end
    end

    def get_region
      reg = region || 'us-east-1'
      raise "Invalid region #{reg} - should be one of #{valid_regions.join(', ')}" unless valid_regions.include?(reg)
      reg
    end

    def generate_uid(name)
      "#{Time.now.strftime '%Y/%m/%d/%H/%M/%S'}/#{SecureRandom.uuid}/#{name}"
    end

    def full_path(uid)
      File.join *[root_path, uid].compact
    end

    def full_storage_headers(headers, meta)
      storage_headers.merge(meta_to_headers(meta)).merge(headers)
    end

    def headers_to_meta(headers)
      json = headers['x-amz-meta-json']
      if json && !json.empty?
        unescape_meta_values(Serializer.json_decode(json))
      elsif marshal_data = headers['x-amz-meta-extra']
        Utils.stringify_keys(Serializer.marshal_b64_decode(marshal_data))
      end
    end

    def meta_to_headers(meta)
      meta = escape_meta_values(meta)
      {'x-amz-meta-json' => Serializer.json_encode(meta)}
    end

    def valid_regions
      REGIONS.keys
    end
    
    def rescuing_all_errors(&block)
      yield
    rescue Excon::Errors::SocketError => e
      LoggerHelper.logger_log('SocketError', e.to_yaml, false)
      storage.reload
      yield
    rescue Aws::S3::MultipartUploadError => e
      LoggerHelper.logger_log('MultipartUploadError', e.to_yaml, false)
      @retry_count += 1
      yield if @retry_count < 3
      raise e if @retry_count >= 3
    rescue => e
      LoggerHelper.logger_log('UnknownError', e.to_yaml, false)
      @retry_count += 1
      yield if @retry_count < 3
      raise e if @retry_count >= 3
    end

    def rescuing_socket_errors(&block)
      yield
    rescue Excon::Errors::SocketError => e
      storage.reload
      yield
    end

    def escape_meta_values(meta)
      meta.inject({}) {|hash, (key, value)|
        hash[key] = value.is_a?(String) ? CGI.escape(value) : value
        hash
      }
    end

    def unescape_meta_values(meta)
      meta.inject({}) {|hash, (key, value)|
        hash[key] = value.is_a?(String) ? CGI.unescape(value) : value
        hash
      }
    end

  end
end
