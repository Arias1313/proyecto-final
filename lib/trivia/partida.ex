
defmodule Trivia.Partida do
  use GenServer

  # ============================================================
  # INICIO Y CONFIGURACION
  # ============================================================

  # Inicia un proceso independiente para cada partida
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

  # Construye el estado inicial de la partida
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
      receptores: %{datos.creador => Map.get(datos, :receptor)},
      puntajes: %{datos.creador => 0},
      bots: [],
      siguiente_bot: 1,
      preguntas: [],
      inicio: nil,
      respuestas_humanos: %{},
      respuesta_humano: nil,
      ronda_abierta: false,
      temporizador: nil,
      inicio_ronda: nil,
      respuestas_bots: %{},
      tiempos_respuesta: %{},
      resultados_ronda: %{},

      # Guarda el momento en que finaliza la partida
      fin: nil
    }

    {:ok, estado}
  end

  # ============================================================
  # CONSULTAR ESTADO
  # ============================================================

  def obtener_estado(pid) do
    GenServer.call(pid, :obtener_estado)
  end

  @impl true
  def handle_call(:obtener_estado, _from, estado) do
    {:reply, {:ok, estado}, estado}
  end

  # ETAPA 27: abandono voluntario o desconexion del creador.
  # La partida procesa el abandono en su propio GenServer para que
  # no se mezcle con las respuestas o con el temporizador.
  def abandonar(pid), do: GenServer.call(pid, :abandonar)

  @impl true
  def handle_call(:abandonar, _from, estado) do
    case estado.estado do
      :esperando ->
        # No hubo preguntas ni puntos: se cancela sin guardar historial.
        detener_bots(estado)
        {:reply, {:ok, "Partida cancelada antes de iniciar"},
         %{estado | estado: :finalizada, fin: DateTime.utc_now()}}

      :jugando ->
        # Conserva solo los puntos de rondas ya cerradas.
        # Una ronda abierta no se puntua parcialmente.
        if estado.temporizador != nil,
          do: Process.cancel_timer(estado.temporizador)

        detener_bots(estado)
        fin = DateTime.utc_now()
        completadas = if estado.ronda_abierta,
          do: estado.pregunta_actual - 1,
          else: estado.pregunta_actual

        mayor = estado.puntajes |> Map.values() |> Enum.max()
        ganadores = estado.puntajes
          |> Enum.filter(fn {_nombre, puntos} -> puntos == mayor end)
          |> Enum.map(fn {nombre, _puntos} -> nombre end)

        resultado = %{
          id: estado.id,
          creador: estado.creador,
          tema: estado.tema,
          nivel: estado.nivel,
          cantidad: length(estado.preguntas),
          tiempo: estado.tiempo,
          jugadores: estado.jugadores,
          puntajes: estado.puntajes,
          ganadores: ganadores,
          inicio: estado.inicio,
          fin: fin,
          motivo_fin: "abandono",
          preguntas_completadas: completadas
        }

        # Solo liberamos la partida si el resultado pudo persistirse.
        case Trivia.Persistencia.guardar_resultado(resultado) do
          {:ok, _} ->
            notificar(estado, "Partida terminada por abandono. Rondas completadas: #{completadas}")
            {:reply, {:ok, "Partida terminada y resultado guardado"},
             %{estado | estado: :finalizada, ronda_abierta: false,
               temporizador: nil, fin: fin}}

          {:error, motivo} ->
            # No se marca como finalizada para permitir reintentar
            # el guardado mediante un nuevo abandono.
            {:reply, {:error, "No se pudo guardar el abandono: #{motivo}"},
             %{estado | ronda_abierta: false, temporizador: nil}}
        end

      :finalizada ->
        detener_bots(estado)
        {:reply, {:ok, "La partida ya estaba finalizada"}, estado}
    end
  end

  # Pide a cada bot que termine su ciclo de recepcion.
  defp detener_bots(estado) do
    Enum.each(estado.bots, fn bot -> send(bot.pid, :detener) end)
  end

  # Un jugador adicional entra solamente mientras se espera el inicio.
  def unirse(pid, usuario, receptor), do: GenServer.call(pid, {:unirse, usuario, receptor})

  @impl true
  def handle_call({:unirse, usuario, receptor}, _from, estado) do
    cond do
      estado.estado != :esperando ->
        {:reply, {:error, "La partida ya inicio"}, estado}
      not is_pid(receptor) ->
        {:reply, {:error, "Receptor invalido"}, estado}
      usuario in estado.jugadores ->
        {:reply, {:error, "Ya participas en esta partida"}, estado}
      length(estado.jugadores) >= 4 ->
        {:reply, {:error, "La partida esta llena"}, estado}
      true ->
        nuevo = %{estado |
          jugadores: estado.jugadores ++ [usuario],
          puntajes: Map.put(estado.puntajes, usuario, 0),
          receptores: Map.put(estado.receptores, usuario, receptor)}
        notificar(nuevo, "#{usuario} se unio a la partida #{estado.id}")
        {:reply, {:ok, "Te uniste a la partida #{estado.id}"}, nuevo}
    end
  end

  # El abandono de un invitado retira su participacion sin cancelar la partida.
  def salir_invitado(pid, usuario), do: GenServer.call(pid, {:salir_invitado, usuario})

  @impl true
  def handle_call({:salir_invitado, usuario}, _from, estado) do
    if usuario == estado.creador or not Map.has_key?(estado.receptores, usuario) do
      {:reply, {:error, "No eres un invitado de esta partida"}, estado}
    else
      nuevo = %{estado |
        jugadores: List.delete(estado.jugadores, usuario),
        receptores: Map.delete(estado.receptores, usuario),
        respuestas_humanos: Map.delete(estado.respuestas_humanos, usuario),
        puntajes: if(estado.estado == :esperando,
          do: Map.delete(estado.puntajes, usuario), else: estado.puntajes)}
      notificar(nuevo, "#{usuario} abandono la partida")
      nuevo = if nuevo.estado == :jugando and nuevo.ronda_abierta,
        do: verificar_respuestas(nuevo), else: nuevo
      {:reply, {:ok, "Abandonaste la partida"}, nuevo}
    end
  end

  # ============================================================
  # AGREGAR BOTS
  # ============================================================

  def agregar_bot(pid, dificultad) do
    GenServer.call(pid, {:agregar_bot, dificultad})
  end

  @impl true
  def handle_call({:agregar_bot, dificultad}, _from, estado) do
    cond do
      dificultad not in ["facil", "dificil"] ->
        {:reply, {:error, "Dificultad invalida"}, estado}

      estado.estado != :esperando ->
        {:reply, {:error, "La partida ya inicio"}, estado}

      length(estado.jugadores) >= 4 ->
        {:reply, {:error, "La partida esta llena"}, estado}

      true ->
        nombre = "bot_#{estado.siguiente_bot}"

        # Inicia un proceso independiente para el bot
        pid_bot = Trivia.Bot.iniciar(nombre, dificultad)

        bot = %{
          nombre: nombre,
          dificultad: dificultad,
          pid: pid_bot
        }

        nuevo_estado = %{
          estado |
          jugadores: estado.jugadores ++ [nombre],
          puntajes: Map.put(estado.puntajes, nombre, 0),
          bots: estado.bots ++ [bot],
          siguiente_bot: estado.siguiente_bot + 1
        }

        {:reply, {:ok, nombre}, nuevo_estado}
    end
  end

  # ============================================================
  # INICIAR EL JUEGO
  # ============================================================

  def iniciar_juego(pid) do
    GenServer.call(pid, :iniciar_juego)
  end

  @impl true
  def handle_call(:iniciar_juego, _from, estado) do
    cond do
      estado.estado != :esperando ->
        {:reply, {:error, "La partida ya inicio"}, estado}

      length(estado.bots) < 2 ->
        {:reply, {:error, "Necesitas al menos 2 bots"}, estado}

      length(estado.bots) > 3 ->
        {:reply, {:error, "El maximo es 3 bots"}, estado}

      true ->
        preparar_inicio(estado)
    end
  end

  # Selecciona las preguntas y comienza el juego
  defp preparar_inicio(estado) do
    case Trivia.BancoPreguntas.preparar_preguntas(
           estado.tema,
           estado.nivel,
           estado.cantidad
         ) do
      {:ok, preguntas} ->
        # Comprueba que haya preguntas disponibles
        if preguntas == [] do
          {:reply, {:error, "No hay preguntas disponibles"}, estado}
        else
          nuevo_estado = %{
            estado |
            preguntas: preguntas,
            estado: :jugando,
            inicio: DateTime.utc_now(),
            pregunta_actual: 1,
            respuesta_humano: nil,
            respuestas_humanos: %{},
            respuestas_bots: %{},
            tiempos_respuesta: %{},
            resultados_ronda: %{}
          }

          # Inicia la primera ronda
          estado_con_ronda = iniciar_ronda(nuevo_estado)

          {:reply, {:ok, "Partida iniciada correctamente"}, estado_con_ronda}
        end

      {:error, motivo} ->
        {:reply, {:error, motivo}, estado}
    end
  end

  # ============================================================
  # RESPUESTAS DEL JUGADOR HUMANO
  # ============================================================

  def responder(pid, usuario, opcion) do
    GenServer.call(pid, {:responder, usuario, opcion})
  end

  @impl true
  def handle_call({:responder, usuario, opcion}, _from, estado) do
    # Convierte la respuesta a mayusculas
    opcion =
      if is_binary(opcion) do
        String.upcase(opcion)
      else
        opcion
      end

    cond do
      estado.estado != :jugando ->
        {:reply, {:error, "La partida no esta en juego"}, estado}

      not Map.has_key?(estado.receptores, usuario) ->
        {:reply, {:error, "No perteneces a esta partida"}, estado}

      # Impide responder durante la pausa entre preguntas
      not estado.ronda_abierta ->
        {:reply, {:error, "La ronda esta cerrada"}, estado}

      tiempo_vencido?(estado) ->
        nuevo_estado = cerrar_ronda(estado, :tiempo_agotado)
        {:reply, {:error, "La ronda esta cerrada"}, nuevo_estado}

      opcion not in ["A", "B", "C", "D"] ->
        {:reply, {:error, "La respuesta debe ser A, B, C o D"}, estado}

      Map.has_key?(estado.respuestas_humanos, usuario) ->
        {:reply, {:error, "Ya respondiste esta pregunta"}, estado}

      true ->
        evaluar_respuesta(estado, usuario, opcion)
    end
  end

  # Registra y comprueba la respuesta del humano
  defp evaluar_respuesta(estado, usuario, opcion) do
    pregunta = Enum.at(estado.preguntas, estado.pregunta_actual - 1)

    if pregunta == nil do
      {:reply, {:error, "No hay una pregunta activa"}, estado}
    else
      # Registra el instante en que llego la respuesta
      instante = System.monotonic_time(:millisecond)

      tiempos =
        Map.put(estado.tiempos_respuesta, usuario, instante)

      nuevo_estado = %{
        estado |
        respuestas_humanos: Map.put(estado.respuestas_humanos, usuario, opcion),
        respuesta_humano: if(usuario == estado.creador, do: opcion, else: estado.respuesta_humano),
        tiempos_respuesta: tiempos
      }

      mensaje =
        if opcion == pregunta["respuesta"] do
          "Respuesta correcta"
        else
          "Respuesta incorrecta"
        end

      # Verifica si ya respondieron todos
      estado_final = verificar_respuestas(nuevo_estado)

      {:reply, {:ok, mensaje}, estado_final}
    end
  end

  # ============================================================
  # INICIAR UNA RONDA
  # ============================================================

  defp iniciar_ronda(estado) do
    # Obtiene la pregunta correspondiente
    pregunta = Enum.at(estado.preguntas, estado.pregunta_actual - 1)

    # Registra el momento de inicio
    inicio_ronda = System.monotonic_time(:millisecond)

    # Programa el cierre cuando se acabe el tiempo
    referencia =
      Process.send_after(
        self(),
        {:tiempo_agotado, estado.pregunta_actual},
        estado.tiempo * 1000
      )

    # Informa el numero de pregunta
    notificar(
      estado,
      "Pregunta #{estado.pregunta_actual} de #{length(estado.preguntas)}"
    )

    # Envia la pregunta a todos los humanos conectados.
    Enum.each(estado.receptores, fn {_usuario, receptor} ->
    if is_pid(receptor) do
      # No enviamos la respuesta correcta al cliente
      pregunta_publica = Map.delete(pregunta, "respuesta")

      send(receptor, {:pregunta, pregunta_publica})

      send(
        receptor,
        {:mensaje, "Tienes #{estado.tiempo} segundos para responder"}
      )
    end

    end)

    # Envia la pregunta completa a los bots
    Enum.each(estado.bots, fn bot ->
      send(
        bot.pid,
        {
          :pregunta,
          pregunta,
          estado.pregunta_actual,
          estado.tiempo,
          self()
        }
      )
    end)

    # Reinicia las respuestas de la nueva ronda
    %{
      estado |
      ronda_abierta: true,
      temporizador: referencia,
      inicio_ronda: inicio_ronda,
      respuesta_humano: nil,
      respuestas_humanos: %{},
      respuestas_bots: %{},
      tiempos_respuesta: %{},
      resultados_ronda: %{}
    }
  end

  # ============================================================
  # RESPUESTAS DE LOS BOTS
  # ============================================================

  @impl true
  def handle_info(
        {:respuesta_bot, nombre, numero_ronda, opcion},
        estado
      ) do
    bot_existe =
      Enum.any?(estado.bots, fn bot ->
        bot.nombre == nombre
      end)

    cond do
      not estado.ronda_abierta ->
        {:noreply, estado}

      numero_ronda != estado.pregunta_actual ->
        {:noreply, estado}

      tiempo_vencido?(estado) ->
        {:noreply, cerrar_ronda(estado, :tiempo_agotado)}

      not bot_existe ->
        {:noreply, estado}

      opcion not in ["A", "B", "C", "D"] ->
        {:noreply, estado}

      Map.has_key?(estado.respuestas_bots, nombre) ->
        {:noreply, estado}

      true ->
        # Guarda la respuesta del bot
        instante = System.monotonic_time(:millisecond)

        respuestas =
          Map.put(estado.respuestas_bots, nombre, opcion)

        tiempos =
          Map.put(estado.tiempos_respuesta, nombre, instante)

        nuevo_estado = %{
          estado |
          respuestas_bots: respuestas,
          tiempos_respuesta: tiempos
        }

        notificar(estado, "#{nombre} ha respondido")

        # Verifica si todos terminaron
        estado_final = verificar_respuestas(nuevo_estado)

        {:noreply, estado_final}
    end
  end

  # ============================================================
  # COMPROBAR SI TODOS RESPONDIERON
  # ============================================================

  defp verificar_respuestas(estado) do
    humano_respondio = Enum.all?(Map.keys(estado.receptores), fn usuario ->
      Map.has_key?(estado.respuestas_humanos, usuario)
    end)

    cantidad_bots = length(estado.bots)
    bots_respondieron = map_size(estado.respuestas_bots)

    if humano_respondio and bots_respondieron == cantidad_bots do
      cerrar_ronda(estado, :todos_respondieron)
    else
      estado
    end
  end

  # ============================================================
  # CONTROL DEL TIEMPO
  # ============================================================

  # Comprueba si se agoto el tiempo de la ronda
  defp tiempo_vencido?(estado) do
    transcurrido =
      System.monotonic_time(:millisecond) - estado.inicio_ronda

    transcurrido >= estado.tiempo * 1000
  end

  # Recibe el aviso del temporizador
  @impl true
  def handle_info({:tiempo_agotado, numero_ronda}, estado) do
    if estado.estado == :jugando and
         estado.ronda_abierta and
         numero_ronda == estado.pregunta_actual do
      nuevo_estado = cerrar_ronda(estado, :tiempo_agotado)
      {:noreply, nuevo_estado}
    else
      # Ignora mensajes de rondas anteriores
      {:noreply, estado}
    end
  end

  # ============================================================
  # CALCULAR PUNTOS
  # ============================================================

  # Puntos por respuesta correcta
  defp puntos_correctos(nivel) do
    case nivel do
      "basico" -> 10
      "intermedio" -> 15
      "avanzado" -> 20
      _ -> 0
    end
  end

  # Penalizacion por respuesta incorrecta
  defp puntos_incorrectos(nivel) do
    case nivel do
      "basico" -> -5
      "intermedio" -> -8
      "avanzado" -> -10
      _ -> 0
    end
  end

  # Calcula la bonificacion por rapidez
  defp calcular_bonificacion(estado, jugador) do
    instante = Map.get(estado.tiempos_respuesta, jugador)

    if instante == nil do
      0
    else
      transcurrido = max(0, instante - estado.inicio_ronda)
      tiempo_total = estado.tiempo * 1000
      restante = max(0, tiempo_total - transcurrido)

      trunc(5 * restante / tiempo_total)
    end
  end

  # Calcula los puntos de una respuesta
  defp calcular_puntos(estado, jugador, opcion, pregunta) do
    nivel = pregunta["nivel"]
    correcta = pregunta["respuesta"]

    cond do
      # No responder no suma ni resta
      opcion == nil ->
        0

      # Respuesta correcta: puntos base y bonificacion
      opcion == correcta ->
        puntos_correctos(nivel) +
          calcular_bonificacion(estado, jugador)

      # Respuesta incorrecta: penalizacion
      true ->
        puntos_incorrectos(nivel)
    end
  end

  # ============================================================
  # PROCESAR RESULTADOS DE LA RONDA
  # ============================================================

  defp procesar_resultados(estado) do
    pregunta = Enum.at(estado.preguntas, estado.pregunta_actual - 1)

    # Junta las respuestas de todos los participantes
    respuestas = Map.merge(estado.respuestas_bots, estado.respuestas_humanos)

    # Calcula los puntos de cada jugador
    {puntajes, resultados} =
      Enum.reduce(
        estado.jugadores,
        {estado.puntajes, %{}},
        fn jugador, {puntajes_acumulados, resultados_acumulados} ->

          opcion = Map.get(respuestas, jugador)

          puntos =
            calcular_puntos(estado, jugador, opcion, pregunta)

          acumulado =
            Map.get(puntajes_acumulados, jugador, 0) + puntos

          nuevos_puntajes =
            Map.put(puntajes_acumulados, jugador, acumulado)

          resultado = %{
            respuesta: opcion,
            puntos: puntos,
            acumulado: acumulado
          }

          nuevos_resultados =
            Map.put(resultados_acumulados, jugador, resultado)

          {nuevos_puntajes, nuevos_resultados}
        end
      )

    nuevo_estado = %{
      estado |
      puntajes: puntajes,
      resultados_ronda: resultados
    }

    mostrar_resultados(nuevo_estado, pregunta)

    nuevo_estado
  end

  # ============================================================
  # MOSTRAR RESULTADOS DE LA RONDA
  # ============================================================

  defp mostrar_resultados(estado, pregunta) do
    notificar(
      estado,
      "===== RESULTADOS RONDA #{estado.pregunta_actual} ====="
    )

    notificar(
      estado,
      "Respuesta correcta: #{pregunta["respuesta"]}"
    )

    Enum.each(estado.jugadores, fn jugador ->
      resultado = Map.get(estado.resultados_ronda, jugador)

      respuesta =
        if resultado.respuesta == nil do
          "Sin responder"
        else
          resultado.respuesta
        end

      notificar(
        estado,
        "#{jugador} | Respuesta: #{respuesta} | " <>
          "Puntos: #{resultado.puntos} | " <>
          "Acumulado: #{resultado.acumulado}"
      )
    end)
  end

  # ============================================================
  # CERRAR LA RONDA
  # ============================================================

  defp cerrar_ronda(estado, motivo) do
    # Cancela el temporizador si sigue activo
    if estado.temporizador != nil do
      Process.cancel_timer(estado.temporizador)
    end

    mensaje =
      case motivo do
        :tiempo_agotado ->
          "Tiempo agotado. La ronda ha terminado"

        :todos_respondieron ->
          "Todos respondieron. La ronda ha terminado"
      end

    notificar(estado, mensaje)

    # Bloquea nuevas respuestas
    estado_cerrado = %{
      estado |
      ronda_abierta: false,
      temporizador: nil
    }

    # Calcula los puntos de la ronda una sola vez
    estado_con_resultados = procesar_resultados(estado_cerrado)

    # Espera 3 segundos antes de avanzar o finalizar
    Process.send_after(
      self(),
      {:continuar_partida, estado.pregunta_actual},
      3000
    )

    notificar(
      estado_con_resultados,
      "Continuando en 3 segundos..."
    )

    estado_con_resultados
  end

  # ============================================================
  # AVANZAR A LA SIGUIENTE PREGUNTA
  # ============================================================

  # Recibe el mensaje programado despues de la pausa
  @impl true
  def handle_info({:continuar_partida, numero_ronda}, estado) do
    cond do
      # Solo debe continuar una partida en juego
      estado.estado != :jugando ->
        {:noreply, estado}

      # Evita que un mensaje viejo cambie otra ronda
      numero_ronda != estado.pregunta_actual ->
        {:noreply, estado}

      # No avanza si la ronda sigue abierta
      estado.ronda_abierta ->
        {:noreply, estado}

      # Si quedan preguntas, avanza a la siguiente
      estado.pregunta_actual < length(estado.preguntas) ->
        nuevo_estado = %{
          estado |
          pregunta_actual: estado.pregunta_actual + 1
        }

        estado_con_ronda = iniciar_ronda(nuevo_estado)

        {:noreply, estado_con_ronda}

      # Si ya se respondieron todas, termina la partida
      true ->
        estado_final = finalizar_partida(estado)

        {:noreply, estado_final}
    end
  end


# ============================================================
# FINALIZAR LA PARTIDA Y GUARDAR RESULTADOS
# ============================================================

defp finalizar_partida(estado) do
  # Ordena a los jugadores de mayor a menor puntaje
  clasificacion =
    Enum.sort_by(
      estado.puntajes,
      fn {_jugador, puntos} -> puntos end,
      :desc
    )

  # Guarda la fecha y hora de finalizacion
  fecha_fin = DateTime.utc_now()

  # Muestra el resumen de la partida
  notificar(estado, "===== PARTIDA FINALIZADA =====")

  notificar(
    estado,
    "Se completaron #{length(estado.preguntas)} preguntas"
  )

  notificar(estado, "===== CLASIFICACION FINAL =====")

  # Muestra los jugadores en orden de puntaje
  clasificacion
  |> Enum.with_index(1)
  |> Enum.each(fn {{jugador, puntos}, posicion} ->
    notificar(
      estado,
      "#{posicion}. #{jugador} - #{puntos} puntos"
    )
  end)

  # Obtiene el puntaje mas alto
  {_primer_jugador, mayor_puntaje} = hd(clasificacion)

  # Busca todos los jugadores que alcanzaron ese puntaje
  ganadores =
    clasificacion
    |> Enum.filter(fn {_jugador, puntos} ->
      puntos == mayor_puntaje
    end)
    |> Enum.map(fn {jugador, _puntos} ->
      jugador
    end)

  # Comprueba si hubo un ganador o un empate
  mensaje_ganadores =
    if length(ganadores) == 1 do
      "Ganador: #{hd(ganadores)}"
    else
      "Empate entre: #{Enum.join(ganadores, ", ")}"
    end

  notificar(estado, mensaje_ganadores)

  notificar(
    estado,
    "Tu puntaje final: #{Map.get(estado.puntajes, estado.creador, 0)}"
  )

  # Construye el resultado que guardaremos en results.log
  resultado = %{
    id: estado.id,
    creador: estado.creador,
    tema: estado.tema,
    nivel: estado.nivel,
    cantidad: length(estado.preguntas),
    tiempo: estado.tiempo,
    jugadores: estado.jugadores,
    puntajes: estado.puntajes,
    ganadores: ganadores,
    inicio: estado.inicio,
    fin: fecha_fin
  }

  # Envia el resultado al GenServer de persistencia
  case Trivia.Persistencia.guardar_resultado(resultado) do
    {:ok, _mensaje} ->
      notificar(
        estado,
        "Resultado guardado correctamente en results.log"
      )

      # Consulta los puntos historicos del jugador
      case Trivia.Persistencia.consultar_puntaje(
             estado.creador,
             estado.tema
           ) do
        {:ok, puntos} ->
          # Calcula el nivel usando los puntos acumulados
          nivel_actual = Trivia.Nivel.obtener_nivel(puntos)

          notificar(
            estado,
            "Puntos acumulados en #{estado.tema}: #{puntos}"
          )

          notificar(
            estado,
            "Tu nivel actual en #{estado.tema}: #{nivel_actual}"
          )

        {:error, motivo} ->
          notificar(
            estado,
            "No se pudo consultar el puntaje historico: #{motivo}"
          )
      end

    {:error, motivo} ->
      notificar(
        estado,
        "Error al guardar el resultado: #{motivo}"
      )
  end

  # Marca la partida como finalizada
  %{
    estado |
    estado: :finalizada,
    ronda_abierta: false,
    temporizador: nil,
    fin: fecha_fin
  }
end


  # ============================================================
  # NOTIFICACIONES AL CLIENTE
  # ============================================================

  # Envia mensajes al receptor del jugador
  defp notificar(estado, mensaje) do
    Enum.each(estado.receptores, fn {_usuario, receptor} ->
      if is_pid(receptor), do: send(receptor, {:mensaje, mensaje})
    end)
  end

end
