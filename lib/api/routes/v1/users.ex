defmodule Lanyard.Api.Routes.V1.Users do
  alias Lanyard.Api.Util
  alias Lanyard.Presence
  alias Lanyard.Connectivity.Redis

  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/@me" do
    case fetch_authenticated_user_id(conn) do
      authenticated_user_id when is_binary(authenticated_user_id) ->
        Util.respond(conn, Presence.get_pretty_presence(authenticated_user_id))

      _ ->
        Util.no_permission(conn)
    end
  end

  get "/:id" do
    %Plug.Conn{params: %{"id" => requested_user_id}} = conn

    case fetch_authenticated_user_id(conn) do
      authenticated_user_id when is_binary(authenticated_user_id) ->
        # Keep API key owner auth separate from requested user ID.
        _ = authenticated_user_id
        Util.respond(conn, Presence.get_pretty_presence(requested_user_id))

      _ ->
        Util.no_permission(conn)
    end
  end

  patch "/:id/kv" do
    %Plug.Conn{params: %{"id" => user_id}} = conn

    {:ok, body, _conn} = Plug.Conn.read_body(conn)

    case validate_resource_access(conn) do
      :ok ->
        try do
          {:ok, parsed} = Jason.decode(body)

          Enum.each(parsed, fn {k, v} ->
            with {:error, _reason} = err <- Lanyard.KV.Interface.validate_pair({k, v}) do
              throw(err)
            end
          end)

          Lanyard.KV.Interface.multiset(user_id, parsed)

          Util.respond(conn, {:ok})
        rescue
          _e ->
            Util.respond(conn, {:error, :invalid_kv_value, "body must be an object"})
        catch
          {:error, reason} -> Util.respond(conn, {:error, :kv_validation_failed, reason})
        end

      :no_permission ->
        Util.no_permission(conn)
    end
  end

  put "/:id/kv/:field" do
    %Plug.Conn{params: %{"id" => user_id, "field" => field}} = conn

    {:ok, put_body, _conn} = Plug.Conn.read_body(conn)

    case validate_resource_access(conn) do
      :ok ->
        case Lanyard.KV.Interface.set(String.to_integer(user_id), field, put_body) do
          {:ok, _v} ->
            Util.respond(conn, {:ok})

          {:error, reason} ->
            Util.respond(conn, {:error, :kv_validation_failed, reason})
        end

      :no_permission ->
        Util.no_permission(conn)
    end
  end

  delete "/:id/kv/:field" do
    %Plug.Conn{params: %{"id" => user_id, "field" => field}} = conn

    case validate_resource_access(conn) do
      :ok ->
        Lanyard.KV.Interface.del(String.to_integer(user_id), field)
        Util.respond(conn, {:ok})

      :no_permission ->
        Util.no_permission(conn)
    end
  end

  match _ do
    Util.not_found(conn)
  end

  defp validate_resource_access(conn) do
    %Plug.Conn{params: %{"id" => user_id}} = conn
    
    case fetch_authenticated_user_id(conn) do
      ^user_id ->
        :ok

      _ ->
        :no_permission
    end
  end

  defp fetch_authenticated_user_id(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      [api_key | _] when is_binary(api_key) and api_key != "" ->
        Redis.get("api_key:#{api_key}")

      _ ->
        nil
    end
  end
end
