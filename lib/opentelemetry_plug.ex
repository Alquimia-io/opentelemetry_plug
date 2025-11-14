defmodule OpentelemetryPlug do
  @moduledoc """
  Telemetry handler for creating OpenTelemetry Spans from Plug events.
  """

  require OpenTelemetry.Tracer, as: Tracer
  alias OpenTelemetry.Span

  defmodule Propagation do
    @moduledoc """
    Adds OpenTelemetry context propagation headers to the Plug response.

    ### WARNING

    These context headers are potentially dangerous to expose to third-parties.
    W3C recommends against including them except in cases where both client and
    server participate in the trace.

    See https://www.w3.org/TR/trace-context/#other-risks for more information.
    """

    @behaviour Plug
    import Plug.Conn, only: [register_before_send: 2, merge_resp_headers: 2]

    @impl true
    def init(opts) do
      opts
    end

    @impl true
    def call(conn, _opts) do
      headers = :otel_propagator_text_map.inject([])
      register_before_send(conn, &merge_resp_headers(&1, headers))
    end
  end

  @doc """
  Attaches the OpentelemetryPlug handler to your Plug.Router events. This
  should be called from your application behaviour on startup.

  Example:

  OpentelemetryPlug.setup()

  """
  def setup() do
    # register the tracer - this function was deprecated in newer versions
    # _ = OpenTelemetry.register_application_tracer(:opentelemetry_plug)

    # Detach existing handlers to prevent crashes on multiple setup() calls
    # (e.g., during hot code reloading or application restarts)
    _ = :telemetry.detach({__MODULE__, :plug_router_start})
    _ = :telemetry.detach({__MODULE__, :plug_router_stop})
    _ = :telemetry.detach({__MODULE__, :plug_router_exception})

    :telemetry.attach(
      {__MODULE__, :plug_router_start},
      [:plug, :router_dispatch, :start],
      &__MODULE__.handle_start/4,
      nil
    )

    :telemetry.attach(
      {__MODULE__, :plug_router_stop},
      [:plug, :router_dispatch, :stop],
      &__MODULE__.handle_stop/4,
      nil
    )

    :telemetry.attach(
      {__MODULE__, :plug_router_exception},
      [:plug, :router_dispatch, :exception],
      &__MODULE__.handle_exception/4,
      nil
    )
  end

  @doc false
  def handle_start(_, _measurements, %{conn: conn, route: route}, _config) do
    # Wrap the entire handler in try/rescue to prevent context leaks on errors
    try do
      save_parent_ctx()

      # Setup OpenTelemetry context based on request headers
      # Gracefully handle malformed headers or extraction errors
      try do
        :otel_propagator_text_map.extract(conn.req_headers)
      rescue
        _ -> :ok
      end

      span_name = "#{route}"

      # Safely extract peer data with defaults for missing values
      peer_data = Plug.Conn.get_peer_data(conn) || %{}

      # Use lowercase header names as Plug.Conn normalizes headers to lowercase
      user_agent = header_or_empty(conn, "user-agent")
      host = header_or_empty(conn, "host")
      peer_ip = Map.get(peer_data, :address)
      peer_port = Map.get(peer_data, :port, 0)

      # Build attributes list, safely handling nil IPs
      attributes =
        [
          "http.target": conn.request_path,
          "http.host": conn.host,
          "http.scheme": conn.scheme,
          "http.flavor": http_flavor(conn.adapter),
          "http.route": route,
          "http.user_agent": user_agent,
          "http.method": conn.method,
          "net.peer.ip": safe_ip_to_string(peer_ip),
          "net.peer.port": peer_port,
          "net.peer.name": host,
          "net.transport": "IP.TCP",
          "net.host.ip": safe_ip_to_string(conn.remote_ip),
          "net.host.port": conn.port
        ] ++ optional_attributes(conn)

      # TODO: Plug should provide a monotonic native time in measurements to use here
      # for the `start_time` option
      span_ctx = Tracer.start_span(span_name, %{attributes: attributes, kind: :server})

      Tracer.set_current_span(span_ctx)
    rescue
      e ->
        # If anything fails, restore the parent context to prevent leaks
        restore_parent_ctx()
        reraise e, __STACKTRACE__
    end
  end

  @doc false
  def handle_stop(_, _measurements, %{conn: conn}, _config) do
    Tracer.set_attribute(:"http.status_code", conn.status)
    # For HTTP status codes in the 4xx and 5xx ranges, as well as any other
    # code the client failed to interpret, status MUST be set to Error.
    #
    # Don't set the span status description if the reason can be inferred from
    # http.status_code.
    if conn.status >= 400 do
      Tracer.set_status(OpenTelemetry.status(:error, ""))
    end

    Tracer.end_span()
    restore_parent_ctx()
  end

  @doc false
  def handle_exception(_, _measurements, metadata, _config) do
    %{kind: kind, stacktrace: stacktrace} = metadata
    # This metadata key changed from :error to :reason in Plug 1.10.3
    reason = metadata[:reason] || metadata[:error]

    exception = Exception.normalize(kind, reason, stacktrace)

    Span.record_exception(
      Tracer.current_span_ctx(),
      exception,
      stacktrace
    )

    Tracer.set_status(OpenTelemetry.status(:error, Exception.message(exception)))
    Tracer.set_attribute(:"http.status_code", 500)
    Tracer.end_span()
    restore_parent_ctx()
  end

  defp header_or_empty(conn, header) do
    case Plug.Conn.get_req_header(conn, header) do
      [] ->
        ""

      [host | _] ->
        host
    end
  end

  defp optional_attributes(conn) do
    ["http.client_ip": &client_ip/1, "http.server_name": &server_name/1]
    |> Enum.map(fn {attr, fun} -> {attr, fun.(conn)} end)
    |> Enum.reject(&is_nil(elem(&1, 1)))
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [] ->
        nil

      [host | _] ->
        host
    end
  end

  defp server_name(_) do
    Application.get_env(:opentelemetry_plug, :server_name, nil)
  end

  defp http_flavor({_adapter_name, meta}) do
    case Map.get(meta, :version) do
      :"HTTP/1.0" -> :"1.0"
      :"HTTP/1.1" -> :"1.1"
      :"HTTP/2.0" -> :"2.0"
      :SPDY -> :SPDY
      :QUIC -> :QUIC
      nil -> ""
    end
  end

  # Safely converts an IP address tuple to string, handling nil values
  defp safe_ip_to_string(nil), do: ""

  defp safe_ip_to_string(ip) do
    try do
      to_string(:inet_parse.ntoa(ip))
    rescue
      _ -> ""
    end
  end

  # Use a stack-based approach to handle nested request contexts
  # This prevents context corruption in nested plug calls
  @ctx_key {__MODULE__, :parent_ctx_stack}

  defp save_parent_ctx() do
    ctx = Tracer.current_span_ctx()
    stack = Process.get(@ctx_key, [])
    Process.put(@ctx_key, [ctx | stack])
  end

  defp restore_parent_ctx() do
    case Process.get(@ctx_key, []) do
      [ctx | rest] ->
        Process.put(@ctx_key, rest)
        # Only restore if the context is valid (not :undefined)
        if ctx != :undefined do
          Tracer.set_current_span(ctx)
        end

      [] ->
        Process.delete(@ctx_key)
        :ok
    end
  end
end
