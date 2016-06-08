require 'net/http/post/multipart'

class BitsClient
  require_relative 'errors'

  def initialize(public_endpoint:, private_endpoint:)
    @public_endpoint = URI.parse(public_endpoint)
    @private_endpoint = URI.parse(private_endpoint)
    @logger = Steno.logger('cc.bits_client')
  end

  def upload_buildpack(buildpack_path, filename)
    with_file_attachment!(buildpack_path, filename) do |file_attachment|
      body = { buildpack: file_attachment }
      multipart_post('/buildpacks', body)
    end
  end

  def delete_buildpack(guid)
    delete("/buildpacks/#{guid}").tap do |response|
      validate_response_code!(204, response)
    end
  end

  def upload_buildpack_cache(key, file_path)
    with_file_attachment!(file_path, nil) do |file_attachment|
      body = { buildpack_cache: file_attachment }
      put("/buildpack_cache/entries/#{key}", body).tap do |response|
        validate_response_code!(201, response)
      end
    end
  end

  def delete_buildpack_cache(key)
    delete("/buildpack_cache/entries/#{key}").tap do |response|
      validate_response_code!(204, response)
    end
  end

  def delete_all_buildpack_caches
    delete('/buildpack_cache/entries').tap do |response|
      validate_response_code!(204, response)
    end
  end

  def upload_droplet(droplet_path)
    with_file_attachment!(droplet_path, nil) do |file_attachment|
      body = { droplet: file_attachment }
      multipart_post('/droplets', body)
    end
  end

  def delete_droplet(guid)
    delete("/droplets/#{guid}").tap do |response|
      validate_response_code!(204, response)
    end
  end

  def upload_package(package_path)
    response = with_file_attachment!(package_path, nil) do |file_attachment|
      body = { package: file_attachment }
      multipart_post('/packages', body)
    end
    JSON.parse(response.body)['guid']
  end

  def delete_package(guid)
    delete("/packages/#{guid}").tap do |response|
      validate_response_code!(204, response)
    end
  end

  def download_package(guid)
    get(download_url(:packages, guid)).tap do |response|
      validate_response_code!(200, response)
    end
  end

  def duplicate_package(guid)
    response = post('/packages', JSON.generate(source_guid: guid))
    validate_response_code!(201, response)
    JSON.parse(response.body)['guid']
  end

  def download_url(resource_type, guid)
    File.join(public_endpoint.to_s, resource_path(resource_type, guid))
  end

  def internal_download_url(resource_type, guid)
    head(resource_path(resource_type, guid)).tap do |response|
      return response['location'] if response.code.to_i == 302
    end
    download_url(resource_type, guid)
  end

  def matches(resources_json)
    post('/app_stash/matches', resources_json).tap do |response|
      validate_response_code!(200, response)
    end
  end

  def upload_entries(entries_path)
    with_file_attachment!(entries_path, 'entries.zip') do |file_attachment|
      body = { application: file_attachment }
      multipart_post('/app_stash/entries', body)
    end
  end

  def bundles(resources_json)
    post('/app_stash/bundles', resources_json).tap do |response|
      validate_response_code!(200, response)
    end
  end

  private

  attr_reader :public_endpoint, :private_endpoint

  def resource_path(resource_type, guid)
    resource_type = 'buildpack_cache/entries' if resource_type.to_sym == :buildpack_cache
    File.join('/', resource_type.to_s, guid.to_s)
  end

  def validate_response_code!(expected, response)
    return if expected.to_i == response.code.to_i

    error = {
      response_code: response.code,
      response_body: response.body,
      response: response
    }.to_json

    @logger.error("UnexpectedResponseCode: expected #{expected} got #{error}")

    fail Errors::UnexpectedResponseCode.new(error)
  end

  def with_file_attachment!(file_path, filename, &block)
    validate_file! file_path

    File.open(file_path) do |file|
      attached_file = UploadIO.new(file, 'application/octet-stream', filename)
      yield attached_file
    end
  end

  def validate_file!(file_path)
    return if File.exist?(file_path)

    raise Errors::FileDoesNotExist.new("Could not find file: #{file_path}")
  end

  def head(path)
    request = Net::HTTP::Head.new(path)
    do_request(request)
  end

  def get(path)
    request = Net::HTTP::Get.new(path)
    do_request(request)
  end

  def post(path, body, header={})
    request = Net::HTTP::Post.new(path, header)

    request.body = body
    do_request(request)
  end

  def put(path, body, header={})
    request = Net::HTTP::Put::Multipart.new(path, body, header)
    do_request(request)
  end

  def multipart_post(path, body, header={})
    request = Net::HTTP::Post::Multipart.new(path, body, header)
    do_request(request).tap do |response|
      validate_response_code!(201, response)
    end
  end

  def delete(path)
    request = Net::HTTP::Delete.new(path)
    do_request(request)
  end

  def do_request(request)
    request_id = SecureRandom.uuid

    http_client = ['GET', 'HEAD'].include?(request.method) ? public_http_client : private_http_client

    @logger.info('Request', {
      method: request.method,
      path: request.path,
      address: http_client.address,
      port: http_client.port,
      vcap_id: VCAP::Request.current_id,
      request_id: request_id
    })
    request.add_field(VCAP::Request::HEADER_NAME, VCAP::Request.current_id)
    http_client.request(request).tap do |response|
      @logger.info('Response', { code: response.code, vcap_id: VCAP::Request.current_id, request_id: request_id })
    end
  end

  def private_http_client
    @private_http_client ||= Net::HTTP.new(private_endpoint.host, private_endpoint.port)
  end

  def public_http_client
    @public_http_client ||= Net::HTTP.new(public_endpoint.host, public_endpoint.port)
  end
end
