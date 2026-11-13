
defmodule Trivia.Application do
  use Application

  @impl true
  def start(_tipo, _argumentos) do

    # Por ahora solo iniciamos procesos en el nodo servidor
    if System.get_env("TRIVIA_ROL") == "servidor" do
      iniciar_servidor()
    else
      Supervisor.start_link([], strategy: :one_for_one)
    end
  end

  defp iniciar_servidor do
    children = [
       Trivia.Persistencia,Trivia.GestorJugadores, Trivia.SupervisorPartidas, Trivia.GestorPartidas, Trivia.Servidor
    ]

    opciones = [
      strategy: :one_for_one,
      name: Trivia.Supervisor
    ]

    Supervisor.start_link(children, opciones)
  end
end
