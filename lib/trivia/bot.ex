
defmodule Trivia.Bot do

  # Inicia un proceso independiente enlazado a la partida
  def iniciar(nombre, dificultad) do
    spawn_link(fn ->
      escuchar(nombre, dificultad)
    end)
  end

  # Mantiene al bot esperando mensajes
  defp escuchar(nombre, dificultad) do
    receive do
      # Permite consultar la informacion del bot
      {:consultar, solicitante} ->
        send(solicitante, {:datos_bot, nombre, dificultad, self()})
        escuchar(nombre, dificultad)

      # Recibe una pregunta enviada por la partida
      {:pregunta, pregunta, numero_ronda, tiempo, partida} ->
        # Elige una respuesta segun la dificultad del bot
        respuesta = elegir_respuesta(pregunta, dificultad)

        # Calcula cuanto tardara el bot en responder
        retraso = calcular_retraso(tiempo)

        # Programa la respuesta sin detener el proceso
        Process.send_after(
          self(),
          {:enviar_respuesta, partida, numero_ronda, respuesta},
          retraso
        )

        escuchar(nombre, dificultad)

      # Envia la respuesta al proceso de la partida
      {:enviar_respuesta, partida, numero_ronda, respuesta} ->
        send(
          partida,
          {:respuesta_bot, nombre, numero_ronda, respuesta}
        )

        escuchar(nombre, dificultad)

      # Permite detener el proceso del bot
      :detener ->
        :ok

      # Ignora mensajes desconocidos
      _otro ->
        escuchar(nombre, dificultad)
    end
  end

  # Selecciona una respuesta segun la dificultad
  defp elegir_respuesta(pregunta, dificultad) do
    correcta = pregunta["respuesta"]

    probabilidad =
      case dificultad do
        "facil" -> 40
        "dificil" -> 80
        _ -> 40
      end

    # Genera un numero aleatorio entre 1 y 100
    numero = :rand.uniform(100)

    if numero <= probabilidad do
      correcta
    else
      # Elige una opcion incorrecta aleatoriamente
      opciones_incorrectas =
        Enum.reject(["A", "B", "C", "D"], fn opcion ->
          opcion == correcta
        end)

      Enum.random(opciones_incorrectas)
    end
  end

  # Calcula el tiempo que tardara en responder el bot
  defp calcular_retraso(tiempo) do
    # Convertimos el tiempo de la ronda a milisegundos
    tiempo_ms = tiempo * 1000

    # El bot responde entre 1 segundo y el 80% del tiempo
    limite = max(1, trunc(tiempo_ms * 0.8))

    minimo = min(1000, limite)

    minimo + :rand.uniform(limite - minimo + 1) - 1
  end

end
