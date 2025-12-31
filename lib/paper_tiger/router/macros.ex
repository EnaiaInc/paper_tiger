defmodule PaperTiger.Router.Macros do
  @moduledoc """
  Macros for generating Stripe resource routes.

  ## Usage

      defmodule MyRouter do
        use Plug.Router
        import PaperTiger.Router.Macros

        stripe_resource("customers", PaperTiger.Resources.Customer, [])
      end
  """

  @doc """
  Generates CRUD routes for a Stripe resource.

  ## Options

  - `:only` - List of actions to generate (default: all)
  - `:except` - List of actions to exclude (default: none)

  ## Actions

  - `:create` - POST /v1/:resource
  - `:retrieve` - GET /v1/:resource/:id
  - `:update` - POST /v1/:resource/:id
  - `:delete` - DELETE /v1/:resource/:id
  - `:list` - GET /v1/:resource

  ## Examples

      stripe_resource("customers", PaperTiger.Resources.Customer, [])
      stripe_resource("tokens", PaperTiger.Resources.Token, only: [:create, :retrieve])
      stripe_resource("events", PaperTiger.Resources.Event, except: [:delete])
  """
  defmacro stripe_resource(resource_name, handler_module, opts \\ []) do
    only = Keyword.get(opts, :only)
    except = Keyword.get(opts, :except, [])

    all_actions = [:create, :retrieve, :update, :delete, :list]

    actions =
      if only do
        only
      else
        all_actions -- except
      end

    routes =
      for action <- actions do
        generate_route(resource_name, handler_module, action)
      end

    quote do
      (unquote_splicing(routes))
    end
  end

  defp generate_route(resource_name, handler_module, :create) do
    path = "/v1/#{resource_name}"

    quote do
      post unquote(path) do
        unquote(handler_module).create(var!(conn))
      end
    end
  end

  defp generate_route(resource_name, handler_module, :retrieve) do
    path = "/v1/#{resource_name}/:id"

    quote do
      get unquote(path) do
        unquote(handler_module).retrieve(var!(conn), var!(conn).path_params["id"])
      end
    end
  end

  defp generate_route(resource_name, handler_module, :update) do
    path = "/v1/#{resource_name}/:id"

    quote do
      post unquote(path) do
        unquote(handler_module).update(var!(conn), var!(conn).path_params["id"])
      end
    end
  end

  defp generate_route(resource_name, handler_module, :delete) do
    path = "/v1/#{resource_name}/:id"

    quote do
      delete unquote(path) do
        unquote(handler_module).delete(var!(conn), var!(conn).path_params["id"])
      end
    end
  end

  defp generate_route(resource_name, handler_module, :list) do
    path = "/v1/#{resource_name}"

    quote do
      get unquote(path) do
        unquote(handler_module).list(var!(conn))
      end
    end
  end
end
