
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
    IO.puts("disconnect")
    IO.puts("ayuda")
    IO.puts("salir")
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

  # ============================================================
  # DESCONEXION Y SALIDA
  # ============================================================

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
