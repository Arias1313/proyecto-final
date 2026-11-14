
defmodule Trivia.Cliente do

  alias Trivia.Servidor
  alias Trivia.Receptor

  # Inicia la consola del cliente
  def iniciar(servidor) do
    estado = %{
      servidor: servidor,
      usuario: nil,
      receptor: nil
    }

    IO.puts("\n===== TRIVIA CONCURRENTE =====")
    IO.puts("Bienvenido al juego")
    mostrar_ayuda()

    ejecutar(estado)
  end

  # Muestra los comandos disponibles
  defp mostrar_ayuda do
    IO.puts("\nComandos disponibles:")
    IO.puts("connect usuario clave")
    IO.puts("conectados")
    IO.puts("create_game tema=<tema> preguntas=<n> tiempo=<segundos>")
    IO.puts("list_games")
    IO.puts("score")
    IO.puts("ranking [tema]")
    IO.puts("add_bot facil|dificil")
    IO.puts("start_game")
    IO.puts("answer A|B|C|D")
    IO.puts("leave_game")
    IO.puts("disconnect")
    IO.puts("ayuda")
    IO.puts("salir")
    IO.puts("join_game ID - Unirse a una partida en espera")
  end

  # Mantiene funcionando la consola
  defp ejecutar(estado) do
    case IO.gets("\nTrivia> ") do
      :eof ->
        cerrar_cliente(estado)

      {:error, motivo} ->
        IO.puts("Error de lectura: #{inspect(motivo)}")
        cerrar_cliente(estado)

      entrada ->
        comando = String.trim(entrada)

        case procesar_comando(comando, estado) do
          {:continuar, nuevo_estado} ->
            ejecutar(nuevo_estado)

          :salir ->
            :ok
        end
    end
  end

  # ============================================================
  # CONEXION DE USUARIOS
  # ============================================================

  # Comando para conectarse
  defp procesar_comando("connect " <> datos, estado) do
    case String.split(datos, ~r/\s+/, trim: true) do
      [usuario, clave] ->
        if estado.usuario != nil do
          IO.puts("Ya tienes una sesion activa")
          {:continuar, estado}
        else
          receptor = Receptor.iniciar()

          respuesta =
            Servidor.solicitar(
              estado.servidor,
              {:connect, usuario, clave, receptor}
            )

          case respuesta do
            {:ok, mensaje} ->
              IO.puts(mensaje)

              nuevo_estado = %{
                estado |
                usuario: usuario,
                receptor: receptor
              }

              {:continuar, nuevo_estado}

            {:error, motivo} ->
              send(receptor, :detener)
              IO.puts("Error: #{motivo}")
              {:continuar, estado}
          end
        end

      _ ->
        IO.puts("Uso: connect usuario clave")
        {:continuar, estado}
    end
  end

  # Lista los jugadores conectados
  defp procesar_comando("conectados", estado) do
    case Servidor.solicitar(estado.servidor, :conectados) do
      {:ok, usuarios} ->
        IO.puts("Jugadores conectados:")
        Enum.each(usuarios, &IO.puts("- #{&1}"))

      {:error, motivo} ->
        IO.puts("Error: #{motivo}")
    end

    {:continuar, estado}
  end

  # ============================================================
  # CREACION Y CONSULTA DE PARTIDAS
  # ============================================================

  # Recibe el comando para crear una partida
  defp procesar_comando("create_game " <> datos, estado) do
    if estado.usuario == nil do
      IO.puts("Debes iniciar sesion primero")
      {:continuar, estado}
    else
      case interpretar_creacion(datos) do
        {:ok, tema, cantidad, tiempo} ->
          respuesta =
            Servidor.solicitar(
              estado.servidor,
              {:create_game, tema, cantidad, tiempo}
            )

          case respuesta do
            {:ok, id, nivel} ->
              IO.puts("\nPartida creada correctamente")
              IO.puts("ID: #{id}")
              IO.puts("Tema: #{tema}")
              IO.puts("Preguntas: #{cantidad}")
              IO.puts("Tiempo: #{tiempo} segundos")
              IO.puts("Nivel: #{nivel}")

            {:error, motivo} ->
              IO.puts("Error: #{motivo}")
          end

          {:continuar, estado}

        {:error, motivo} ->
          IO.puts("Error: #{motivo}")
          {:continuar, estado}
      end
    end
  end

  # Interpreta los parametros tema, preguntas y tiempo
  defp interpretar_creacion(datos) do
    partes = String.split(datos, ~r/\s+/, trim: true)

    case partes do
      [tema_param, preguntas_param, tiempo_param] ->
        with "tema=" <> tema <- tema_param,
             "preguntas=" <> cantidad_texto <- preguntas_param,
             "tiempo=" <> tiempo_texto <- tiempo_param,
             {cantidad, ""} <- Integer.parse(cantidad_texto),
             {tiempo, ""} <- Integer.parse(tiempo_texto) do

          {:ok, tema, cantidad, tiempo}
        else
          _ ->
            {:error, "Uso: create_game tema=<tema> preguntas=<n> tiempo=<segundos>"}
        end

      _ ->
        {:error, "Uso: create_game tema=<tema> preguntas=<n> tiempo=<segundos>"}
    end
  end

  # Consulta las partidas existentes
  defp procesar_comando("list_games", estado) do
    case Servidor.solicitar(estado.servidor, :list_games) do
      {:ok, []} ->
        IO.puts("No hay partidas registradas")

      {:ok, partidas} ->
        IO.puts("\n===== PARTIDAS =====")

        Enum.each(partidas, fn partida ->
          IO.puts(
            "ID: #{partida.id} | " <>
            "Creador: #{partida.creador} | " <>
            "Tema: #{partida.tema} | " <>
            "Preguntas: #{partida.cantidad} | " <>
            "Nivel: #{partida.nivel}"
          )
        end)

      {:error, motivo} ->
        IO.puts("Error: #{motivo}")
    end

    {:continuar, estado}
  end

  # Unirse a una partida creada por otro jugador.
  defp procesar_comando("join_game " <> texto_id, estado) do
    if estado.usuario == nil do
      IO.puts("Debes iniciar sesion primero")
    else
      case Integer.parse(String.trim(texto_id)) do
        {id, ""} when id > 0 ->
          case Servidor.solicitar(estado.servidor, {:join_game, id}) do
            {:ok, mensaje} -> IO.puts(mensaje)
            {:error, motivo} -> IO.puts("Error: #{motivo}")
          end
        _ -> IO.puts("Uso: join_game ID")
      end
    end
    {:continuar, estado}
  end

  # ============================================================
  # AGREGAR BOTS A LA PARTIDA
  # ============================================================

  # Permite agregar un bot a la partida del usuario conectado
  defp procesar_comando("add_bot " <> dificultad, estado) do
    if estado.usuario == nil do
      IO.puts("Debes iniciar sesion primero")
    else
      # Envia al servidor la dificultad solicitada
      respuesta =
        Servidor.solicitar(
          estado.servidor,
          {:add_bot, String.trim(dificultad)}
        )

      # Muestra si el bot fue agregado o si hubo un error
      case respuesta do
        {:ok, nombre} ->
          IO.puts("Bot agregado correctamente: #{nombre}")

        {:error, motivo} ->
          IO.puts("Error: #{motivo}")
      end
    end

    {:continuar, estado}
  end

  # ============================================================
  # INICIO DE LA PARTIDA
  # ============================================================

  # Solicita iniciar la partida creada por el jugador
  defp procesar_comando("start_game", estado) do
    if estado.usuario == nil do
      IO.puts("Debes iniciar sesion primero")
    else
      # Envia la solicitud al servidor
      respuesta =
        Servidor.solicitar(
          estado.servidor,
          :start_game
        )

      # Comprueba si la partida pudo iniciar
      case respuesta do
        {:ok, mensaje} ->
          IO.puts(mensaje)

        {:error, motivo} ->
          IO.puts("Error: #{motivo}")
      end
    end

    {:continuar, estado}
  end

  # ============================================================
  # RESPUESTAS A LAS PREGUNTAS
  # ============================================================

  # Permite responder una pregunta usando A, B, C o D
  defp procesar_comando("answer " <> opcion, estado) do
    if estado.usuario == nil do
      IO.puts("Debes iniciar sesion primero")
    else
      # Envia la respuesta al servidor para que sea validada
      respuesta =
        Servidor.solicitar(
          estado.servidor,
          {:answer, String.trim(opcion)}
        )

      # Muestra si la respuesta fue correcta o incorrecta
      case respuesta do
        {:ok, mensaje} ->
          IO.puts(mensaje)

        {:error, motivo} ->
          IO.puts("Error: #{motivo}")
      end
    end

    {:continuar, estado}
  end

  # ============================================================

  # ============================================================
  # ETAPA 26: PUNTAJE HISTORICO Y RANKING
  # ============================================================

  # Consulta el puntaje historico del usuario conectado.
  defp procesar_comando("score", estado) do
    case Servidor.solicitar(estado.servidor, :score) do
      {:ok, datos} ->
        IO.puts("\n===== #{datos.usuario} =====")
        IO.puts("Puntaje acumulado: #{datos.total}")
        IO.puts("Partidas jugadas: #{datos.partidas}")
        IO.puts("\nTema | Puntaje | Nivel")

        Enum.each(datos.temas, fn tema ->
          IO.puts("#{tema.tema} | #{tema.puntos} | #{tema.nivel}")
        end)

        if datos.temas == [], do: IO.puts("Aun no has jugado partidas")

      {:error, motivo} ->
        IO.puts("Error: #{motivo}")
    end

    {:continuar, estado}
  end

  # Muestra el ranking historico de todos los temas.
  defp procesar_comando("ranking", estado) do
    mostrar_ranking(estado, nil)
    {:continuar, estado}
  end

  # Muestra el ranking de un tema concreto.
  defp procesar_comando("ranking " <> tema, estado) do
    mostrar_ranking(estado, String.trim(tema))
    {:continuar, estado}
  end

  defp mostrar_ranking(estado, tema) do
    case Servidor.solicitar(estado.servidor, {:ranking, tema}) do
      {:ok, jugadores} ->
        titulo = if tema == nil, do: "global", else: "de #{tema}"
        IO.puts("\n===== Ranking #{titulo} =====")
        IO.puts("# | Jugador | Puntaje | Partidas")

        jugadores
        |> Enum.with_index(1)
        |> Enum.each(fn {jugador, posicion} ->
          IO.puts("#{posicion} | #{jugador.usuario} | #{jugador.puntos} | #{jugador.partidas}")
        end)

        if jugadores == [], do: IO.puts("No hay resultados registrados")

      {:error, motivo} ->
        IO.puts("Error: #{motivo}")
    end
  end

  # DESCONEXION Y SALIDA
  # ============================================================

  # ETAPA 27: abandona la partida, pero conserva la sesion.
  defp procesar_comando("leave_game", estado) do
    case Servidor.solicitar(estado.servidor, :leave_game) do
      {:ok, mensaje} -> IO.puts(mensaje)
      {:error, motivo} -> IO.puts("Error: #{motivo}")
    end
    {:continuar, estado}
  end

  # Cierra la sesion actual
  defp procesar_comando("disconnect", estado) do
    if estado.usuario == nil do
      IO.puts("No tienes una sesion activa")
      {:continuar, estado}
    else
      respuesta = Servidor.solicitar(estado.servidor, :disconnect)
      IO.inspect(respuesta)

      if match?({:ok, _}, respuesta) do
        send(estado.receptor, :detener)

        nuevo_estado = %{
          estado |
          usuario: nil,
          receptor: nil
        }

        {:continuar, nuevo_estado}
      else
        {:continuar, estado}
      end
    end
  end

  # Muestra los comandos disponibles
  defp procesar_comando("ayuda", estado) do
    mostrar_ayuda()
    {:continuar, estado}
  end

  # Finaliza el cliente
  defp procesar_comando("salir", estado) do
    cerrar_cliente(estado)
    :salir
  end

  # Ignora entradas vacias
  defp procesar_comando("", estado) do
    {:continuar, estado}
  end

  # Maneja comandos desconocidos
  defp procesar_comando(_, estado) do
    IO.puts("Comando desconocido. Escribe ayuda.")
    {:continuar, estado}
  end

  # Limpia la sesion antes de salir
  defp cerrar_cliente(estado) do
    if estado.usuario != nil do
      Servidor.solicitar(estado.servidor, :disconnect)

      if is_pid(estado.receptor) do
        send(estado.receptor, :detener)
      end
    end

    IO.puts("Cliente finalizado")
    :ok
  end
end
