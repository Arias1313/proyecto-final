
defmodule Trivia.SupervisorPartidas do
  use DynamicSupervisor

  # Inicia el supervisor de partidas
  def start_link(_) do
    DynamicSupervisor.start_link(
      __MODULE__,
      [],
      name: __MODULE__
    )
  end

  @impl true
  def init(_) do
    DynamicSupervisor.init(
      strategy: :one_for_one
    )
  end

  # Inicia una nueva partida
  def iniciar_partida(datos) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {Trivia.Partida, datos}
    )
  end

  # Detiene una partida existente
  def detener_partida(pid) do
    DynamicSupervisor.terminate_child(
      __MODULE__,
      pid
    )
  end

  # Consulta la cantidad de partidas activas
  def contar_partidas do
    DynamicSupervisor.count_children(__MODULE__)
  end
end
