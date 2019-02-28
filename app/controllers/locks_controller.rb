# frozen_string_literal: true
class LocksController < ResourceController
  before_action :set_resource, only: [:create, :destroy]
  before_action :authorize_resource!

  def create
    super(fallback_location: root_path, redirect_on_html_error: true)
  end

  private

  def resource_params
    super.permit(
      :description,
      :resource_id,
      :resource_type,
      :warning,
      :delete_in,
      :delete_at
    ).merge(user: current_user)
  end

  def set_resource
    if action_name == 'destroy' && !params[:id]
      # NOTE: using .fetch instead of .require since we support "" as meaning "global"
      id = params.fetch(:resource_id).presence
      type = params.fetch(:resource_type).presence
      raise if !type ^ !id # global or exact are ok, but not just id or just type
      assign_resource Lock.where(resource_id: id, resource_type: type).first!
    else
      super
    end
  end

  # TODO: make CurrentUser handle dynamic scopes and remove this
  def authorize_resource!
    unauthorized! unless can?(resource_action, controller_name.to_sym, @lock&.resource)
  end
end
