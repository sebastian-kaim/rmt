class Api::Connect::V3::Systems::ProductsController < Api::Connect::BaseController

  before_action :authenticate_system
  before_action :require_product, only: %i[show activate upgrade destroy]
  before_action :check_base_product_dependencies, only: %i[activate upgrade show]

  def activate
    create_product_activation
    render_service
  end

  def show
    if @system.products.include? @product
      respond_with(
        @product,
        serializer: ::V3::ProductSerializer,
        base_url: request.base_url
      )
    else
      raise ActionController::TranslatedError.new(N_("The requested product '%s' is not activated on this system."), @product.friendly_name)
    end
  end

  def migrations
    require_params([:installed_products])

    installed_products = params[:installed_products].map { |hash| product_from_hash(hash) rescue nil }.compact

    begin
      upgrade_paths = MigrationEngine.new(@system, installed_products).generate

      render json: (
        upgrade_paths.reject(&:empty?).map do |item|
          ActiveModelSerializers::SerializableResource.new(
            item,
            each_serializer: ::V3::UpgradePathItemSerializer
          )
        end
      ).to_json
    rescue MigrationEngine::MigrationEngineError => e
      raise ActionController::TranslatedError.new(e.message, *e.data)
    end
  end

  def upgrade
    activation = @system.activations.joins(:service).find_by('services.product_id': [@product.id, @product.predecessor_ids, @product.successor_ids].flatten)

    unless activation
      raise ActionController::TranslatedError.new(
        N_("No activation with product '%s' was found."),
        @product.friendly_name
      )
    end

    activation.service = @product.service
    activation.save!

    render_service
  end

  protected

  def require_product
    require_params(%i[identifier version arch])

    @product = Product.where(identifier: params[:identifier], version: params[:version], arch: params[:arch]).first

    unless @product
      raise ActionController::TranslatedError.new(N_('No product found'))
    end
    check_product_service_and_repositories
  end

  def check_product_service_and_repositories
    unless @product.service && @product.repositories.present?
      fail ActionController::TranslatedError.new(N_('No repositories found for product: %s'), @product.friendly_name)
    end

    mandatory_repos = @product.repositories.where({ enabled: true })
    mirrored_repos = @product.repositories.where({ enabled: true, mirroring_enabled: true })

    unless (mandatory_repos.size == mirrored_repos.size)
      fail ActionController::TranslatedError.new(N_('Not all mandatory repositories are mirrored for product %s'), @product.friendly_name)
    end
  end

  def create_product_activation
    @system.activations.where(service_id: @product.service.id).first_or_create
  end

  # Check if extension base product is already activated
  def check_base_product_dependencies
    # TODO: For APIv5 and future. We skip this check for second level extensions. E.g. HA-GEO
    # To fix bnc#951189 specifically the rollback part of it.
    return if @product.bases.any?(&:extension?)
    return if @product.base? || (@system.products & @product.bases).present?

    logger.info("Tried to activate/upgrade to '#{@product.friendly_name}' with unmet base product dependency")
    raise ActionController::TranslatedError.new(
      N_('Unmet product dependencies, please activate one of these products first: %s'),
      @product.bases.map(&:friendly_name).join(', ')
    )
  end

  def render_service
    status = ((request.put? || request.post?) ? 201 : 200)
    # manually setting request method, so respond_with actually renders content also for PUT
    request.instance_variable_set(:@request_method, 'GET')

    respond_with(
      @product.service,
      serializer: ::V3::ServiceSerializer,
      base_url: request.base_url,
      obsoleted_service_name: @obsoleted_service_name,
      status: status
    )
  end

  def product_search_params(product_hash)
    product_hash.permit(:identifier, :version, :arch, :release_type).to_h.symbolize_keys
  end

  def product_from_hash(product_hash)
    Product.find_by(product_search_params(product_hash))
  end

end
