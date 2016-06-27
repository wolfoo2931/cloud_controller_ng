require 'presenters/system_env_presenter'

module VCAP::CloudController
  class AppsController < RestController::ModelController
    def self.dependencies
      [:app_event_repository, :droplet_blobstore]
    end

    define_attributes do
      attribute :enable_ssh,              Message::Boolean, default: nil
      attribute :buildpack,               String,           default: nil
      attribute :command,                 String,           default: nil
      attribute :console,                 Message::Boolean, default: false
      attribute :diego,                   Message::Boolean, default: nil
      attribute :docker_image,            String,           default: nil
      attribute :docker_credentials_json, Hash,             default: {}, redact_in: [:create, :update]
      attribute :debug,                   String,           default: nil
      attribute :disk_quota,              Integer,          default: nil
      attribute :environment_json,        Hash,             default: {}
      attribute :health_check_type,       String,           default: 'port'
      attribute :health_check_timeout,    Integer,          default: nil
      attribute :instances,               Integer,          default: 1
      attribute :memory,                  Integer,          default: nil
      attribute :name,                    String
      attribute :production,              Message::Boolean, default: false
      attribute :state,                   String,           default: 'STOPPED'
      attribute :detected_start_command,  String,           exclude_in: [:create, :update]
      attribute :ports,                   [Integer],        default: nil

      to_one :space
      to_one :stack, optional_in: :create

      to_many :routes
      to_many :events,              link_only: true
      to_many :service_bindings,    exclude_in: :create
      to_many :route_mappings,      link_only: true, exclude_in: [:create, :update], route_for: :get
    end

    query_parameters :name, :space_guid, :organization_guid, :diego, :stack_guid

    get '/v2/apps/:guid/env', :read_env

    def read_env(guid)
      FeatureFlag.raise_unless_enabled!(:env_var_visibility)
      app = find_guid_and_validate_access(:read_env, guid, App)
      FeatureFlag.raise_unless_enabled!(:space_developer_env_var_visibility)

      vcap_application = VCAP::VarsBuilder.new(app).to_hash

      [
        HTTP::OK,
        {},
        MultiJson.dump({
          staging_env_json:     EnvironmentVariableGroup.staging.environment_json,
          running_env_json:     EnvironmentVariableGroup.running.environment_json,
          environment_json:     app.environment_json,
          system_env_json:      SystemEnvPresenter.new(app.all_service_bindings).system_env,
          application_env_json: { 'VCAP_APPLICATION' => vcap_application },
        }, pretty: true)
      ]
    end

    def self.translate_validation_exception(e, attributes)
      space_and_name_errors  = e.errors.on([:space_id, :name])
      memory_errors          = e.errors.on(:memory)
      instance_number_errors = e.errors.on(:instances)
      app_instance_limit_errors = e.errors.on(:app_instance_limit)
      state_errors           = e.errors.on(:state)
      docker_errors          = e.errors.on(:docker)
      diego_to_dea_errors    = e.errors.on(:diego_to_dea)

      if space_and_name_errors
        CloudController::Errors::ApiError.new_from_details('AppNameTaken', attributes['name'])
      elsif memory_errors
        translate_memory_validation_exception(memory_errors)
      elsif instance_number_errors
        CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Number of instances less than 0')
      elsif app_instance_limit_errors
        if app_instance_limit_errors.include?(:space_app_instance_limit_exceeded)
          CloudController::Errors::ApiError.new_from_details('SpaceQuotaInstanceLimitExceeded')
        else
          CloudController::Errors::ApiError.new_from_details('QuotaInstanceLimitExceeded')
        end
      elsif state_errors
        CloudController::Errors::ApiError.new_from_details('AppInvalid', 'Invalid app state provided')
      elsif docker_errors && docker_errors.include?(:docker_disabled)
        CloudController::Errors::ApiError.new_from_details('DockerDisabled')
      elsif diego_to_dea_errors
        CloudController::Errors::ApiError.new_from_details('MultipleAppPortsMappedDiegoToDea')
      else
        CloudController::Errors::ApiError.new_from_details('AppInvalid', e.errors.full_messages)
      end
    end

    def self.translate_memory_validation_exception(memory_errors)
      if memory_errors.include?(:space_quota_exceeded)
        CloudController::Errors::ApiError.new_from_details('SpaceQuotaMemoryLimitExceeded')
      elsif memory_errors.include?(:space_instance_memory_limit_exceeded)
        CloudController::Errors::ApiError.new_from_details('SpaceQuotaInstanceMemoryLimitExceeded')
      elsif memory_errors.include?(:quota_exceeded)
        CloudController::Errors::ApiError.new_from_details('AppMemoryQuotaExceeded')
      elsif memory_errors.include?(:zero_or_less)
        CloudController::Errors::ApiError.new_from_details('AppMemoryInvalid')
      elsif memory_errors.include?(:instance_memory_limit_exceeded)
        CloudController::Errors::ApiError.new_from_details('QuotaInstanceMemoryLimitExceeded')
      end
    end

    def inject_dependencies(dependencies)
      super
      @app_event_repository = dependencies.fetch(:app_event_repository)
      @blobstore = dependencies.fetch(:droplet_blobstore)
    end

    def delete(guid)
      app = find_guid_and_validate_access(:delete, guid)

      if !recursive_delete? && app.service_bindings.present?
        raise CloudController::Errors::ApiError.new_from_details('AssociationNotEmpty', 'service_bindings', app.class.table_name)
      end

      AppDelete.new(SecurityContext.current_user.guid, SecurityContext.current_user_email).delete(app.app)

      @app_event_repository.record_app_delete_request(
        app,
        app.space,
        SecurityContext.current_user.guid,
        SecurityContext.current_user_email,
        recursive_delete?)

      [HTTP::NO_CONTENT, nil]
    end

    get '/v2/apps/:guid/droplet/download', :download_droplet
    def download_droplet(guid)
      app = find_guid_and_validate_access(:read, guid)
      blob_dispatcher.send_or_redirect_blob(app.current_droplet.try(:blob))
    rescue CloudController::Errors::BlobNotFound
      raise CloudController::Errors::ApiError.new_from_details('ResourceNotFound', "Droplet not found for app with guid #{app.guid}")
    end

    private

    def blob_dispatcher
      BlobDispatcher.new(blobstore: @blobstore, controller: self)
    end

    def before_update(app)
      verify_enable_ssh(app.space)
      updated_diego_flag = request_attrs['diego']
      ports = request_attrs['ports']
      ignore_empty_ports! if ports == []
      if should_warn_about_changed_ports?(app.diego, updated_diego_flag, ports)
        add_warning('App ports have changed but are unknown. The app should now listen on the port specified by environment variable PORT.')
      end
      return if request_attrs['route'].blank?
      route = Route.find(guid: request_attrs['route'])
      begin
        RouteMappingValidator.new(route, app).validate
      rescue RouteMappingValidator::RouteInvalidError
        raise CloudController::Errors::ApiError.new_from_details('RouteNotFound', request_attrs['route_guid'])
      rescue RouteMappingValidator::TcpRoutingDisabledError
        raise CloudController::Errors::ApiError.new_from_details('TcpRoutingDisabled')
      end
    end

    def ignore_empty_ports!
      @request_attrs = @request_attrs.deep_dup
      @request_attrs.delete 'ports'
      @request_attrs.freeze
    end

    def should_warn_about_changed_ports?(old_diego, new_diego, ports)
      !new_diego.nil? && old_diego && !new_diego && ports.nil?
    end

    def verify_enable_ssh(space)
      app_enable_ssh = request_attrs['enable_ssh']
      global_allow_ssh = VCAP::CloudController::Config.config[:allow_app_ssh_access]
      ssh_allowed = global_allow_ssh && (space.allow_ssh || roles.admin?)

      if app_enable_ssh && !ssh_allowed
        raise CloudController::Errors::ApiError.new_from_details(
          'InvalidRequest',
          'enable_ssh must be false due to global allow_ssh setting',
          )
      end
    end

    def after_update(app)
      stager_response = app.last_stager_response
      if stager_response.respond_to?(:streaming_log_url) && stager_response.streaming_log_url
        set_header('X-App-Staging-Log', stager_response.streaming_log_url)
      end

      if app.dea_update_pending?
        Dea::Client.update_uris(app)
      end

      @app_event_repository.record_app_update(app, app.space, SecurityContext.current_user.guid, SecurityContext.current_user_email, request_attrs)
    end

    def create
      json_msg = self.class::CreateMessage.decode(body)

      @request_attrs = json_msg.extract(stringify_keys: true)

      logger.debug 'cc.create', model: self.class.model_class_name, attributes: redact_attributes(:create, request_attrs)

      space = VCAP::CloudController::Space[guid: request_attrs['space_guid']]
      verify_enable_ssh(space)

      app = nil
      model.db.transaction do
        v3_app = AppModel.create(
          name:                  request_attrs['name'],
          space_guid:            request_attrs['space_guid'],
          environment_variables: request_attrs['environment_json']
        )

        app = App.create(
          guid:                    v3_app.guid,
          name:                    request_attrs['name'],
          environment_json:        request_attrs['environment_json'],
          production:              request_attrs['production'],
          space_guid:              request_attrs['space_guid'],
          stack_guid:              request_attrs['stack_guid'],
          buildpack:               request_attrs['buildpack'],
          memory:                  request_attrs['memory'],
          instances:               request_attrs['instances'],
          disk_quota:              request_attrs['disk_quota'],
          state:                   request_attrs['state'],
          command:                 request_attrs['command'],
          console:                 request_attrs['console'],
          debug:                   request_attrs['debug'],
          health_check_type:       request_attrs['health_check_type'],
          health_check_timeout:    request_attrs['health_check_timeout'],
          diego:                   request_attrs['diego'],
          docker_image:            request_attrs['docker_image'],
          enable_ssh:              request_attrs['enable_ssh'],
          docker_credentials_json: request_attrs['docker_credentials_json'],
          ports:                   request_attrs['ports'],
          route_guids:             request_attrs['route_guids'],
          service_binding_guids:   request_attrs['service_binding_guids'],
          app:                     v3_app
        )

        validate_access(:create, app, request_attrs)
      end

      @app_event_repository.record_app_create(
        app,
        app.space,
        SecurityContext.current_user.guid,
        SecurityContext.current_user_email,
        request_attrs)

      [
        HTTP::CREATED,
        { 'Location' => "#{self.class.path}/#{app.guid}" },
        object_renderer.render_json(self.class, app, @opts)
      ]
    end

    def filter_dataset(dataset)
      dataset.where(type: 'web')
    end

    define_messages
    define_routes
  end
end
