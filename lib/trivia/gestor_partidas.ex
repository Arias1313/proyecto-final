
defmodule Trivia.GestorPartidas do
  use GenServer

  alias Trivia.SupervisorPartidas
  alias Trivia.Partida

  # Inicia el gestor
  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{},
      name: __MODULE__
    )
  end

  @impl true
  def init(_) do
    estado = %{
      partidas: %{},
      contador: 0
    }

    {:ok, estado}
  end

  # Solicita crear una partida
  def crear_partida(creador, tema, cantidad, tiempo) do
    GenServer.call(
      __MODULE__,
      {:crear_partida, creador, tema, cantidad, tiempo}
    )
  end

  # Procesa la creacion
  @impl true
  def handle_call(
        {:crear_partida, creador, tema, cantidad, tiempo},
        _from,
        estado
      ) do

    case validar_datos(creador, tema, cantidad, tiempo) do
      :ok ->
        id = estado.contador + 1

        datos = %{
          id: id,
          creador: creador,
          tema: tema,
          cantidad: cantidad,
          tiempo: tiempo
        }

        case SupervisorPartidas.iniciar_partida(datos) do
          {:ok, pid} ->
            referencia = Process.monitor(pid)

            informacion = %{
              pid: pid,
              referencia: referencia,
              creador: creador,
              tema: tema,
              cantidad: cantidad,
              tiempo: tiempo
            }

            partidas =
              Map.put(estado.partidas, id, informacion)

            nuevo_estado = %{
              estado |
              partidas: partidas,
              contador: id
            }

            {:reply, {:ok, id}, nuevo_estado}

          {:error, motivo} ->
            {:reply, {:error, inspect(motivo)}, estado}
        end

      {:error, motivo} ->
        {:reply, {:error, motivo}, estado}
    end
  end

  # Valida los datos recibidos
  defp validar_datos(creador, tema, cantidad, tiempo) do
    temas = ["ciencia", "historia", "geografia", "tecnologia"]

    cond do
      not is_binary(creador) or String.trim(creador) == "" ->
        {:error, "Creador invalido"}

      tema not in temas ->
        {:error, "Tema no permitido"}

      not is_integer(cantidad) or cantidad < 1 ->
        {:error, "Cantidad de preguntas invalida"}

      cantidad > 24 ->
        {:error, "El maximo por tema es 24 preguntas"}

      not is_integer(tiempo) or tiempo <= 0 ->
        {:error, "Tiempo invalido"}

      true ->
        :ok
    end
  end

  # Consulta todas las partidas
  def listar_partidas do
    GenServer.call(__MODULE__, :listar_partidas)
  end

  @impl true
  def handle_call(:listar_partidas, _from, estado) do
    partidas =
      Enum.map(estado.partidas, fn {id, datos} ->
        %{
          id: id,
          creador: datos.creador,
          tema: datos.tema,
          cantidad: datos.cantidad,
          tiempo: datos.tiempo
        }
      end)

    {:reply, {:ok, Enum.sort_by(partidas, & &1.id)}, estado}
  end

  # Consulta una partida especifica
  def obtener_partida(id) do
    GenServer.call(__MODULE__, {:obtener_partida, id})
  end

  @impl true
  def handle_call({:obtener_partida, id}, _from, estado) do
    case Map.get(estado.partidas, id) do
      nil ->
        {:reply, {:error, "Partida no encontrada"}, estado}

      datos ->
        respuesta = Partida.obtener_estado(datos.pid)
        {:reply, respuesta, estado}
    end
  end

  # Elimina del registro las partidas que terminan
  @impl true
  def handle_info({:DOWN, referencia, :process, _pid, _motivo}, estado) do
    partidas =
      Enum.reject(estado.partidas, fn {_id, datos} ->
        datos.referencia == referencia
      end)
      |> Map.new()

    {:noreply, %{estado | partidas: partidas}}
  end
end
