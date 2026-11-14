defmodule Trivia.Bot do
  # Cada bot es un proceso independiente enlazado a su partida.
  # Si la partida falla, el bot termina con ella.
  def iniciar(nombre, dificultad) do
    spawn_link(fn -> escuchar(nombre, dificultad) end)
  end

  # Mantiene el proceso del bot esperando mensajes.
  defp escuchar(nombre, dificultad) do
    receive do
      {:consultar, solicitante} ->
        send(solicitante, {:datos_bot, nombre, dificultad, self()})
        escuchar(nombre, dificultad)

      # La partida envia la pregunta, su numero, el tiempo y su propio PID.
      {:pregunta, pregunta, numero_ronda, tiempo, partida} ->
        case decidir(pregunta, dificultad, tiempo) do
          {:ok, respuesta, retraso} ->
            # El bot programa su respuesta sin bloquear su proceso.
            Process.send_after(
              self(),
              {:enviar_respuesta, partida, numero_ronda, respuesta},
              retraso
            )

          {:error, _motivo} ->
            # Una pregunta invalida no debe hacer caer al bot.
            :ok
        end

        escuchar(nombre, dificultad)

      # La partida recibe exactamente el mismo formato de mensaje de antes.
      {:enviar_respuesta, partida, numero_ronda, respuesta} ->
        send(partida, {:respuesta_bot, nombre, numero_ronda, respuesta})
        escuchar(nombre, dificultad)

      :detener ->
        :ok

      _otro ->
        escuchar(nombre, dificultad)
    end
  end

  # Funcion separada para facilitar las pruebas automaticas.
  # Retorna la opcion elegida y el retraso en milisegundos.
  def decidir(pregunta, dificultad, tiempo) when is_map(pregunta) do
    nivel = pregunta["nivel"]
    correcta = pregunta["respuesta"]

    cond do
      dificultad not in ["facil", "dificil"] ->
        {:error, "Dificultad de bot invalida"}

      nivel not in ["basico", "intermedio", "avanzado"] ->
        {:error, "Nivel de pregunta invalido"}

      correcta not in ["A", "B", "C", "D"] ->
        {:error, "Respuesta correcta invalida"}

      not is_integer(tiempo) or tiempo <= 0 ->
        {:error, "Tiempo de pregunta invalido"}

      true ->
        probabilidad = probabilidad_acierto(dificultad, nivel)
        respuesta = elegir_respuesta(correcta, probabilidad)
        retraso = calcular_retraso(dificultad, tiempo)
        {:ok, respuesta, retraso}
    end
  end

  def decidir(_, _, _), do: {:error, "Pregunta invalida"}

  # Porcentaje de acierto segun la dificultad del bot y de la pregunta.
  defp probabilidad_acierto("facil", "basico"), do: 40
  defp probabilidad_acierto("facil", "intermedio"), do: 30
  defp probabilidad_acierto("facil", "avanzado"), do: 20
  defp probabilidad_acierto("dificil", "basico"), do: 80
  defp probabilidad_acierto("dificil", "intermedio"), do: 70
  defp probabilidad_acierto("dificil", "avanzado"), do: 60

  # Sortea un numero de 1 a 100 para decidir si acierta.
  defp elegir_respuesta(correcta, probabilidad) do
    if :rand.uniform(100) <= probabilidad do
      correcta
    else
      # Si falla, elige solo entre las otras tres opciones.
      ["A", "B", "C", "D"]
      |> Enum.reject(fn opcion -> opcion == correcta end)
      |> Enum.random()
    end
  end

  # Calcula el instante de respuesta dentro del intervalo exigido.
  # Se trabaja en milisegundos para permitir tiempos fraccionarios.
  defp calcular_retraso(dificultad, tiempo) do
    tiempo_ms = tiempo * 1000

    {porcentaje_minimo, porcentaje_maximo} =
      case dificultad do
        "facil" -> {40, 90}
        "dificil" -> {10, 40}
      end

    minimo = div(tiempo_ms * porcentaje_minimo, 100)
    maximo = div(tiempo_ms * porcentaje_maximo, 100)

    # Ambos extremos del intervalo estan incluidos.
    minimo + :rand.uniform(maximo - minimo + 1) - 1
  end
end
