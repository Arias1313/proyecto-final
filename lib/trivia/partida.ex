
defmodule Trivia.Partida do
  use GenServer

  # Inicia un proceso independiente para la partida
  def start_link(datos) do
    GenServer.start_link(__MODULE__, datos)
  end

  # Configura la supervision de las partidas
  @impl true
  def child_spec(datos) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [datos]},
      restart: :transient
    }
  end

  # Construye el estado inicial
  @impl true
  def init(datos) do
    estado = %{
      id: datos.id,
      creador: datos.creador,
      tema: datos.tema,
      cantidad: datos.cantidad,
      tiempo: datos.tiempo,
      receptor: Map.get(datos, :receptor),
      nivel: datos.nivel,
      estado: :esperando,
      pregunta_actual: 0,
      jugadores: [datos.creador],
      puntajes: %{datos.creador => 0}
    }

    {:ok, estado}
  end

  # Consulta el estado de una partida
  def obtener_estado(pid) do
    GenServer.call(pid, :obtener_estado)
  end

  @impl true
  def handle_call(:obtener_estado, _from, estado) do
    {:reply, {:ok, estado}, estado}
  end
end
