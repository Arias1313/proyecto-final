
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

    # Antes de crear una nueva partida, retiramos las que ya terminaron.
    estado_limpio = limpiar_partidas_finalizadas(estado)

    case validar_creacion(creador, tema, cantidad, tiempo, receptor, estado_limpio) do
      :ok ->
        case Persistencia.consultar_nivel(creador, tema) do
          {:ok, nivel} ->
            iniciar_nueva_partida(
              creador, tema, cantidad, tiempo,
              receptor, nivel, estado_limpio
            )

          {:error, motivo} ->
            {:reply, {:error, motivo}, estado_limpio}
        end

      {:error, motivo} ->
        {:reply, {:error, motivo}, estado_limpio}
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
          receptor: receptor,
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
    {:ok, temas} = Trivia.BancoPreguntas.temas_disponibles()

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

      %{recuperando: true} ->
        {:reply, {:error, "La partida se esta recuperando, intenta nuevamente"}, estado}

      datos ->
        respuesta = Partida.obtener_estado(datos.pid)
        {:reply, respuesta, estado}
    end
  end

  # ============================================================
  # ETAPA 28B: RECUPERACION DE PARTIDAS QUE FALLAN
  # ============================================================

  # El gestor monitorea cada partida. Cuando un proceso termina,
  # recibimos su referencia, el PID anterior y el motivo.
  @impl true
  def handle_info({:DOWN, referencia, :process, pid_anterior, motivo}, estado) do
    encontrada =
      Enum.find(estado.partidas, fn {_id, datos} ->
        datos.referencia == referencia
      end)

    case encontrada do
      nil ->
        # Puede ser un monitor que ya retiramos durante una limpieza.
        {:noreply, estado}

      {id, datos} ->
        if motivo in [:normal, :shutdown] or
             (is_tuple(motivo) and elem(motivo, 0) == :shutdown) do
          # Una terminacion normal NO debe reiniciar la partida.
          {:noreply, %{estado | partidas: Map.delete(estado.partidas, id)}}
        else
          # :transient permite al DynamicSupervisor reiniciar el hijo.
          # La busqueda se hace en otro mensaje para darle tiempo al supervisor.
          datos_pendientes = Map.put(datos, :recuperando, true)
          partidas = Map.put(estado.partidas, id, datos_pendientes)
          Process.send_after(self(), {:recuperar_partida, id, pid_anterior, 1}, 100)
          {:noreply, %{estado | partidas: partidas}}
        end
    end
  end

  # Reintenta la busqueda si el supervisor aun esta reiniciando al hijo.
  @impl true
  def handle_info({:recuperar_partida, id, pid_anterior, intento}, estado) do
    case Map.get(estado.partidas, id) do
      %{pid: ^pid_anterior, recuperando: true} = datos ->
        case buscar_pid_reiniciado(id, pid_anterior) do
          {:ok, nuevo_pid} ->
            nueva_referencia = Process.monitor(nuevo_pid)
            datos_actualizados =
              datos
              |> Map.put(:pid, nuevo_pid)
              |> Map.put(:referencia, nueva_referencia)
              |> Map.delete(:recuperando)

            # El proceso reiniciado solo conserva al creador; los invitados
            # deben volver a unirse a la partida desde sus clientes.
            Enum.each(Map.get(datos, :invitados, []), fn usuario ->
              case Map.get(datos, :receptores_invitados, %{}) |> Map.get(usuario) do
                receptor when is_pid(receptor) ->
                  send(receptor, {:mensaje, "La partida #{id} se reinicio. Usa join_game #{id} para volver a entrar."})
                _ -> :ok
              end
            end)
            datos_actualizados = datos_actualizados
              |> Map.put(:invitados, [])
              |> Map.put(:receptores_invitados, %{})
            partidas = Map.put(estado.partidas, id, datos_actualizados)

            if is_pid(datos.receptor) do
              send(datos.receptor, {:mensaje,
                "La partida #{id} fallo y fue reiniciada desde cero. Agrega nuevos bots y ejecuta start_game."})
            end

            {:noreply, %{estado | partidas: partidas}}

          :no_encontrada when intento < 20 ->
            Process.send_after(self(),
              {:recuperar_partida, id, pid_anterior, intento + 1}, 100)
            {:noreply, estado}

          :no_encontrada ->
            # Si el supervisor no pudo recuperarla, liberamos el registro.
            if is_pid(datos.receptor) do
              send(datos.receptor, {:mensaje,
                "No fue posible recuperar la partida #{id}. Puedes crear otra."})
            end
            {:noreply, %{estado | partidas: Map.delete(estado.partidas, id)}}
        end

      _ ->
        # Se retiro o reemplazo la partida mientras esperabamos.
        {:noreply, estado}
    end
  end

  # Los hijos de DynamicSupervisor no tienen un ID unico en which_children/1.
  # Por eso buscamos el proceso vivo cuyo estado contiene el ID de la partida.
  defp buscar_pid_reiniciado(id, pid_anterior) do
    hijos = DynamicSupervisor.which_children(Trivia.SupervisorPartidas)

    Enum.find_value(hijos, :no_encontrada, fn {_hijo_id, pid, _tipo, _modulos} ->
      if is_pid(pid) and pid != pid_anterior and Process.alive?(pid) do
        # Un hijo puede terminar justo durante la consulta; eso no debe
        # provocar que falle el GestorPartidas.
        try do
          case GenServer.call(pid, :obtener_estado, 1000) do
            {:ok, %{id: ^id}} -> {:ok, pid}
            _ -> false
          end
        catch
          :exit, _ -> false
        end
      else
        false
      end
    end)
  end


# Permite que otro usuario entre en una partida en espera.
def unirse_partida(id, usuario, receptor) do
  GenServer.call(__MODULE__, {:unirse_partida, id, usuario, receptor})
end

@impl true
def handle_call({:unirse_partida, id, usuario, receptor}, _from, estado) do
  estado = limpiar_partidas_finalizadas(estado)
  ocupado = Enum.any?(estado.partidas, fn {_otro_id, datos} ->
    datos.creador == usuario or usuario in Map.get(datos, :invitados, [])
  end)
  cond do
    ocupado -> {:reply, {:error, "Ya estas participando en otra partida"}, estado}
    not Map.has_key?(estado.partidas, id) ->
      {:reply, {:error, "Partida no encontrada"}, estado}
    Map.get(estado.partidas[id], :recuperando, false) ->
      {:reply, {:error, "La partida se esta recuperando"}, estado}
    true ->
      datos = estado.partidas[id]
      case Partida.unirse(datos.pid, usuario, receptor) do
        {:ok, _} = respuesta ->
          actualizado = datos
            |> Map.update(:invitados, [usuario], &(&1 ++ [usuario]))
            |> Map.update(:receptores_invitados, %{usuario => receptor}, &Map.put(&1, usuario, receptor))
          {:reply, respuesta, put_in(estado, [:partidas, id], actualizado)}
        error -> {:reply, error, estado}
      end
  end
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

    %{recuperando: true} ->
      {:reply, {:error, "La partida se esta recuperando, intenta nuevamente"}, estado}

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

    %{recuperando: true} ->
      {:reply, {:error, "La partida se esta recuperando, intenta nuevamente"}, estado}

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
      datos.creador == usuario or usuario in Map.get(datos, :invitados, [])
    end)

  case encontrada do
    nil ->
      {:reply, {:error, "No participas en una partida"}, estado}

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
          datos.creador == creador or creador in Map.get(datos, :invitados, [])
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

    {_id, %{recuperando: true}} ->
      {:reply, {:error, "La partida se esta recuperando, intenta nuevamente"}, estado}

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
      datos.creador == usuario or usuario in Map.get(datos, :invitados, [])
    end)

  case encontrada do
    nil ->
      {:reply, {:error, "No participas en una partida"}, estado}

    {_id, %{recuperando: true}} ->
      {:reply, {:error, "La partida se esta recuperando, intenta nuevamente"}, estado}

    {_id, datos} ->
      respuesta = Trivia.Partida.responder(datos.pid, usuario, opcion)
      {:reply, respuesta, estado}
  end
end





  # ETAPA 27: abandonar la partida del usuario, si existe.
  def abandonar_partida(usuario) do
    GenServer.call(__MODULE__, {:abandonar_partida, usuario})
  end

  @impl true
  def handle_call({:abandonar_partida, usuario}, _from, estado) do
    encontrada = Enum.find(estado.partidas, fn {_id, datos} ->
      datos.creador == usuario or usuario in Map.get(datos, :invitados, [])
    end)

    case encontrada do
      nil ->
        {:reply, {:error, "No tienes una partida creada"}, estado}

      {_id, %{recuperando: true}} ->
        {:reply, {:error, "La partida se esta recuperando, intenta nuevamente"}, estado}

      {id, datos} when datos.creador != usuario ->
        case Partida.salir_invitado(datos.pid, usuario) do
          {:ok, _} = respuesta ->
            actualizado = datos
              |> Map.update!(:invitados, &List.delete(&1, usuario))
              |> Map.update(:receptores_invitados, %{}, &Map.delete(&1, usuario))
            {:reply, respuesta, put_in(estado, [:partidas, id], actualizado)}
          error -> {:reply, error, estado}
        end

      {id, datos} ->
        # Consultamos y finalizamos en el proceso de la partida.
        # Si la persistencia falla, mantenemos el registro para reintentar.
        if Process.alive?(datos.pid) do
          case Partida.abandonar(datos.pid) do
            {:ok, mensaje} ->
              Process.demonitor(datos.referencia, [:flush])
              GenServer.stop(datos.pid, :normal)
              nuevo = %{estado | partidas: Map.delete(estado.partidas, id)}
              {:reply, {:ok, mensaje}, nuevo}

            {:error, motivo} ->
              {:reply, {:error, motivo}, estado}
          end
        else
          Process.demonitor(datos.referencia, [:flush])
          nuevo = %{estado | partidas: Map.delete(estado.partidas, id)}
          {:reply, {:error, "El proceso de la partida ya no existe"}, nuevo}
        end
    end
  end

  # Retira las partidas finalizadas del registro del gestor.
  # No borra resultados del historial. Las partidas que estan siendo
  # recuperadas se conservan hasta que el supervisor las reinicie.
  defp limpiar_partidas_finalizadas(estado) do
    partidas_activas =
      Enum.reduce(estado.partidas, %{}, fn {id, datos}, acumulado ->
        cond do
          Map.get(datos, :recuperando, false) ->
            Map.put(acumulado, id, datos)

          not Process.alive?(datos.pid) ->
            Process.demonitor(datos.referencia, [:flush])
            acumulado

          true ->
            case Partida.obtener_estado(datos.pid) do
              {:ok, %{estado: :finalizada} = partida} ->
                Enum.each(partida.bots, fn bot -> send(bot.pid, :detener) end)
                Process.demonitor(datos.referencia, [:flush])
                GenServer.stop(datos.pid, :normal)
                acumulado

              {:ok, _partida} ->
                Map.put(acumulado, id, datos)
            end
        end
      end)

    %{estado | partidas: partidas_activas}
  end
end
