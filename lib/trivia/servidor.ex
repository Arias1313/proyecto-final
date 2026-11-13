
defmodule Trivia.Servidor do
  use GenServer

  alias Trivia.GestorJugadores
  alias Trivia.GestorPartidas

  # Inicia el servidor
  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{sesiones: %{}},
      name: __MODULE__
    )
  end

  @impl true
  def init(estado) do
    {:ok, estado}
  end

  # Envia solicitudes al servidor remoto
  def solicitar(servidor, peticion) do
    try do
      GenServer.call({__MODULE__, servidor}, peticion, 5000)
    catch
      :exit, _ ->
        {:error, "No se pudo comunicar con el servidor"}
    end
  end

  # Conecta un usuario y registra su proceso receptor
  @impl true
  def handle_call(
        {:connect, usuario, clave, pid_receptor},
        {pid_cliente, _},
        estado
      ) when is_pid(pid_receptor) do

    if node(pid_receptor) != node(pid_cliente) do
      {:reply, {:error, "Receptor de otro nodo"}, estado}
    else
      sesion_existente =
        buscar_sesion(estado.sesiones, pid_cliente)

      if sesion_existente != nil do
        {:reply, {:error, "Ya tienes una sesion activa"}, estado}
      else
        case GestorJugadores.conectar(usuario, clave) do
          {:ok, mensaje} ->
            referencia = Process.monitor(pid_receptor)

            sesion = %{
              usuario: usuario,
              cliente: pid_cliente,
              receptor: pid_receptor
            }

            sesiones = Map.put(estado.sesiones, referencia, sesion)

            {:reply, {:ok, mensaje}, %{estado | sesiones: sesiones}}

          {:error, motivo} ->
            {:reply, {:error, motivo}, estado}
        end
      end
    end
  end

  @impl true
  def handle_call({:connect, _, _, _}, _from, estado) do
    {:reply, {:error, "Proceso receptor invalido"}, estado}
  end

  # Cierra la sesion del proceso solicitante
  @impl true
  def handle_call(:disconnect, {pid_cliente, _}, estado) do
    encontrado =
      Enum.find(estado.sesiones, fn {_ref, sesion} ->
        sesion.cliente == pid_cliente
      end)

    case encontrado do
      nil ->
        {:reply, {:error, "No tienes una sesion activa"}, estado}

      {referencia, sesion} ->
        Process.demonitor(referencia, [:flush])
        GestorJugadores.cerrar_sesion(sesion.usuario)

        sesiones = Map.delete(estado.sesiones, referencia)

        {:reply, {:ok, "Sesion cerrada correctamente"},
         %{estado | sesiones: sesiones}}
    end
  end

  # Consulta los jugadores conectados
  @impl true
  def handle_call(:conectados, _from, estado) do
    respuesta = GestorJugadores.listar_conectados()
    {:reply, respuesta, estado}
  end

  # Crea una partida para el cliente conectado
  @impl true
  def handle_call(
        {:create_game, tema, cantidad, tiempo},
        {pid_cliente, _},
        estado
      ) do

    case buscar_sesion(estado.sesiones, pid_cliente) do
      nil ->
        {:reply, {:error, "Debes iniciar sesion"}, estado}

      sesion ->
        respuesta =
          GestorPartidas.crear_partida(
            sesion.usuario,
            tema,
            cantidad,
            tiempo,
            sesion.receptor
          )

        {:reply, respuesta, estado}
    end
  end

  # Lista las partidas disponibles
  @impl true
  def handle_call(:list_games, {pid_cliente, _}, estado) do
    case buscar_sesion(estado.sesiones, pid_cliente) do
      nil ->
        {:reply, {:error, "Debes iniciar sesion"}, estado}

      _sesion ->
        {:reply, GestorPartidas.listar_partidas(), estado}
    end
  end

  # Busca la sesion correspondiente al proceso cliente
  defp buscar_sesion(sesiones, pid_cliente) do
    Enum.find_value(sesiones, fn {_referencia, sesion} ->
      if sesion.cliente == pid_cliente do
        sesion
      else
        nil
      end
    end)
  end

  # Detecta cuando desaparece un receptor
  @impl true
  def handle_info(
        {:DOWN, referencia, :process, _pid, _motivo},
        estado
      ) do

    case Map.pop(estado.sesiones, referencia) do
      {nil, _} ->
        {:noreply, estado}

      {sesion, sesiones} ->
        GestorJugadores.cerrar_sesion(sesion.usuario)

        {:noreply, %{estado | sesiones: sesiones}}
    end
  end
end
