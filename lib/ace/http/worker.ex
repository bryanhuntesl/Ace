defmodule Ace.HTTP.Worker do
  @moduledoc false
  use GenServer

  def child_spec({module, config}) do
    # DEBT is module previously checked to implement Raxx.Application or Raxx.Server
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [{module, config}]},
      type: :worker,
      restart: :temporary,
      shutdown: 500
    }
  end

  # TODO decide whether a channel should be limited from startup to single channel (stream/pipeline)
  def start_link({module, config}, channel \\ nil) do
    GenServer.start_link(__MODULE__, {module, config, nil}, [])
  end

  ## Server Callbacks

  def handle_info({client, request = %Raxx.Request{}}, {mod, state, nil}) do
    mod.handle_headers(request, state)
    |> normalise_reaction({mod, state, client})
  end
  def handle_info({client, fragment = %Raxx.Fragment{}}, {mod, state, client}) do
    false = fragment.end_stream
    mod.handle_fragment(fragment.data, state)
    |> normalise_reaction({mod, state, client})
  end
  def handle_info({client, trailer = %Raxx.Trailer{}}, {mod, state, client}) do
    mod.handle_trailers(trailer.headers, state)
    |> normalise_reaction({mod, state, client})
  end

  def handle_info(other, {mod, state, client}) do
    mod.handle_info(other, state)
    |> normalise_reaction({mod, state, client})
  end

  defp normalise_reaction(response = %Raxx.Response{}, {mod, state, client}) do
    send_client(client, response)
    if Raxx.complete?(response) do
      {:stop, :normal, {mod, state, client}}
    else
      {:noreply, {mod, state, client}}
    end
  end
  defp normalise_reaction({parts, new_state}, {mod, _old_state, client}) do
    Enum.each(parts, fn(part) -> send_client(client, part) end)
    {:noreply, {mod, new_state, client}}
  end

  defp send_client(ref = {:http1, pid, _count}, part) do
    send(pid, {ref, part})
  end
  # TODO remove this special case
  defp send_client(stream = {:stream, _, _, _}, {:promise, request}) do
    request = request
    |> Map.put(:scheme, request.scheme || :https)
    Ace.HTTP2.send(stream, {:promise, request})
  end
  defp send_client(stream = {:stream, _, _, _}, part) do
    Ace.HTTP2.send(stream, part)
  end
end
