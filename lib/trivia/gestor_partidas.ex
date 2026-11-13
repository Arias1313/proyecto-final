
defmodule Trivia.GestorPartidas do
  use GenServer

  alias Trivia.SupervisorPartidas
  alias Trivia.Partida
  alias Trivia.Persistencia

  # Inicia el gestor de partidas
  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{},
      name: __MODULE__
    )
  end

  @impl true
  def init(_) do
    {:ok, %{partidas: %{}, contador: 0}}
  end

  # Mantiene la funcion utilizada en pruebas anteriores
  def crear_partida(creador, tema, cantidad, tiempo) do
    crear_partida(creador, tema, cantidad, tiempo, nil)
  end

  # Crea una partida con el receptor del jugador
  def crear_partida(creador, tema, cantidad, tiempo, receptor) do
    GenServer.call(
      __MODULE__,
      {:crear_partida, creador, tema, cantidad, tiempo, receptor}
    )
  end

  # Procesa la solicitud de creacion
  @impl true
  def handle_call(
        {:crear_partida, creador, tema, cantidad, tiempo, receptor},
        _from,
        estado
      ) do

    case validar_creacion(creador, tema, cantidad, tiempo, receptor, estado) do
      :ok ->
        case Persistencia.consultar_nivel(creador, tema) do
          {:ok, nivel} ->
            iniciar_nueva_partida(
              creador, tema, cantidad, tiempo,
              receptor, nivel, estado
            )

          {:error, motivo} ->
            {:reply, {:error, motivo}, estado}
        end

      {:error, motivo} ->
        {:reply, {:error, motivo}, estado}
    end
  end

  # Inicia el proceso individual de la partida
  defp iniciar_nueva_partida(
         creador, tema, cantidad, tiempo,
         receptor, nivel, estado
       ) do

    id = estado.contador + 1

    datos = %{
      id: id,
      creador: creador,
      tema: tema,
      cantidad: cantidad,
      tiempo: tiempo,
      receptor: receptor,
      nivel: nivel
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
          tiempo: tiempo,
          nivel: nivel
        }

        partidas = Map.put(estado.partidas, id, informacion)

        nuevo_estado = %{
          estado |
          partidas: partidas,
          contador: id
        }

        {:reply, {:ok, id, nivel}, nuevo_estado}

      {:error, motivo} ->
        {:reply, {:error, inspect(motivo)}, estado}
    end
  end

  # Valida los datos de la partida
  defp validar_datos(creador, tema, cantidad, tiempo, receptor) do
    temas = ["ciencia", "historia", "geografia", "tecnologia"]

    cond do
      not is_binary(creador) or String.trim(creador) == "" ->
        {:error, "Creador invalido"}

      tema not in temas ->
        {:error, "Tema no permitido"}

      not is_integer(cantidad) or cantidad < 1 or cantidad > 10 ->
        {:error, "La cantidad debe estar entre 1 y 10"}

      not is_integer(tiempo) or tiempo <= 0 ->
        {:error, "Tiempo invalido"}

      receptor != nil and not is_pid(receptor) ->
        {:error, "Receptor invalido"}

      true ->
        :ok
    end
  end

  # Lista las partidas registradas
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
          tiempo: datos.tiempo,
          nivel: datos.nivel
        }
      end)

    {:reply, {:ok, Enum.sort_by(partidas, & &1.id)}, estado}
  end

  # Consulta una partida por su identificador
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

  # Elimina del registro una partida cuyo proceso termino
  @impl true
  def handle_info({:DOWN, referencia, :process, _pid, _motivo}, estado) do
    partidas =
      estado.partidas
      |> Enum.reject(fn {_id, datos} ->
        datos.referencia == referencia
      end)
      |> Map.new()

    {:noreply, %{estado | partidas: partidas}}
  end


# Solicita agregar un bot a una partida
def agregar_bot(id, dificultad) do
  GenServer.call(
    __MODULE__,
    {:agregar_bot, id, dificultad}
  )
end

# Busca la partida y agrega el bot
@impl true
def handle_call({:agregar_bot, id, dificultad}, _from, estado) do
  case Map.get(estado.partidas, id) do
    nil ->
      {:reply, {:error, "Partida no encontrada"}, estado}

    datos ->
      respuesta = Trivia.Partida.agregar_bot(
        datos.pid,
        dificultad
      )

      {:reply, respuesta, estado}
  end
end


# Agrega un bot comprobando que el usuario sea el creador
def agregar_bot(id, dificultad, usuario) do
  GenServer.call(
    __MODULE__,
    {:agregar_bot, id, dificultad, usuario}
  )
end

# Comprueba que la partida pertenezca al usuario
@impl true
def handle_call(
      {:agregar_bot, id, dificultad, usuario},
      _from,
      estado
    ) do

  case Map.get(estado.partidas, id) do
    nil ->
      {:reply, {:error, "Partida no encontrada"}, estado}

    datos ->
      if datos.creador != usuario do
        {:reply, {:error, "No eres el creador de esta partida"}, estado}
      else
        respuesta =
          Trivia.Partida.agregar_bot(datos.pid, dificultad)

        {:reply, respuesta, estado}
      end
  end
end

# Busca la partida que pertenece a un jugador
def buscar_partida_usuario(usuario) do
  GenServer.call(
    __MODULE__,
    {:buscar_partida_usuario, usuario}
  )
end

@impl true
def handle_call({:buscar_partida_usuario, usuario}, _from, estado) do
  encontrada =
    Enum.find(estado.partidas, fn {_id, datos} ->
      datos.creador == usuario
    end)

  case encontrada do
    nil ->
      {:reply, {:error, "No tienes una partida creada"}, estado}

    {id, _datos} ->
      {:reply, {:ok, id}, estado}
  end
end



# Comprueba los datos y que el jugador no tenga otra partida activa
defp validar_creacion(creador, tema, cantidad, tiempo, receptor, estado) do
  case validar_datos(creador, tema, cantidad, tiempo, receptor) do
    :ok ->
      ya_tiene_partida =
        Enum.any?(estado.partidas, fn {_id, datos} ->
          datos.creador == creador
        end)

      if ya_tiene_partida do
        {:error, "Ya tienes una partida activa"}
      else
        :ok
      end

    {:error, motivo} ->
      {:error, motivo}
  end
end


# Solicita iniciar la partida de un jugador
def iniciar_partida(usuario) do
  GenServer.call(__MODULE__, {:iniciar_partida, usuario})
end

@impl true
def handle_call({:iniciar_partida, usuario}, _from, estado) do
  encontrada =
    Enum.find(estado.partidas, fn {_id, datos} ->
      datos.creador == usuario
    end)

  case encontrada do
    nil ->
      {:reply, {:error, "No tienes una partida creada"}, estado}

    {_id, datos} ->
      respuesta = Trivia.Partida.iniciar_juego(datos.pid)
      {:reply, respuesta, estado}
  end
end


# Solicita responder una pregunta de la partida del jugador
def responder(usuario, opcion) do
  GenServer.call(__MODULE__, {:responder, usuario, opcion})
end

@impl true
def handle_call({:responder, usuario, opcion}, _from, estado) do
  encontrada =
    Enum.find(estado.partidas, fn {_id, datos} ->
      datos.creador == usuario
    end)

  case encontrada do
    nil ->
      {:reply, {:error, "No tienes una partida creada"}, estado}

    {_id, datos} ->
      respuesta = Trivia.Partida.responder(datos.pid, usuario, opcion)
      {:reply, respuesta, estado}
  end
end





end
