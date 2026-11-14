defmodule Trivia.ReglasTest do
  use ExUnit.Case, async: true

  alias Trivia.{Nivel, BancoPreguntas, Bot, Persistencia}

  # Prueba 1: limites de los niveles por puntaje historico.
  test "los niveles cambian en 60 y 180 puntos" do
    assert Nivel.obtener_nivel(0) == "basico"
    assert Nivel.obtener_nivel(59) == "basico"
    assert Nivel.obtener_nivel(60) == "intermedio"
    assert Nivel.obtener_nivel(179) == "intermedio"
    assert Nivel.obtener_nivel(180) == "avanzado"
  end

  # Prueba 2: el nivel rechaza datos no numericos.
  test "rechaza puntajes no numericos" do
    assert {:error, _} = Nivel.obtener_nivel("cien")
  end

  # Prueba 3: mezcla de preguntas para un jugador basico.
  test "distribucion basica de diez preguntas" do
    assert Nivel.distribuir_preguntas("basico", 10) ==
             %{basico: 7, intermedio: 3, avanzado: 0}
  end

  # Prueba 4: mezcla de preguntas para un jugador intermedio.
  test "distribucion intermedia de diez preguntas" do
    assert Nivel.distribuir_preguntas("intermedio", 10) ==
             %{basico: 2, intermedio: 6, avanzado: 2}
  end

  # Prueba 5: mezcla de preguntas para un jugador avanzado.
  test "distribucion avanzada de diez preguntas" do
    assert Nivel.distribuir_preguntas("avanzado", 10) ==
             %{basico: 0, intermedio: 3, avanzado: 7}
  end

  # Prueba 6: valores de nivel y cantidad incorrectos.
  test "rechaza distribuciones invalidas" do
    assert {:error, _} = Nivel.distribuir_preguntas("experto", 10)
    assert {:error, _} = Nivel.distribuir_preguntas("basico", 0)
    assert {:error, _} = Nivel.distribuir_preguntas("basico", -1)
  end

  # Prueba 7: una pregunta con cuatro opciones validas es aceptada.
  test "acepta una pregunta bien formada" do
    pregunta = pregunta_valida()
    assert {:ok, ^pregunta} = BancoPreguntas.validar_pregunta(pregunta)
  end

  # Prueba 8: rechaza una pregunta sin opcion D.
  test "rechaza preguntas con opciones incompletas" do
    pregunta = pregunta_valida()
    incompleta = put_in(pregunta["opciones"], %{"A" => "Uno", "B" => "Dos", "C" => "Tres"})
    assert {:error, _} = BancoPreguntas.validar_pregunta(incompleta)
  end

  # Prueba 9: rechaza preguntas con respuesta fuera de A-D.
  test "rechaza respuesta correcta invalida" do
    assert {:error, _} = BancoPreguntas.validar_pregunta(%{pregunta_valida() | "respuesta" => "E"})
  end

  # Prueba 10: bot facil responde dentro del tiempo definido.
  test "bot facil usa respuestas validas y retraso del 40 al 90 por ciento" do
    assert {:ok, respuesta, retraso} = Bot.decidir(pregunta_valida(), "facil", 10)
    assert respuesta in ["A", "B", "C", "D"]
    assert retraso >= 4_000 and retraso <= 9_000
  end

  # Prueba 11: bot dificil responde antes que el facil, en su intervalo.
  test "bot dificil usa retraso del 10 al 40 por ciento" do
    assert {:ok, respuesta, retraso} = Bot.decidir(pregunta_valida(), "dificil", 10)
    assert respuesta in ["A", "B", "C", "D"]
    assert retraso >= 1_000 and retraso <= 4_000
  end

  # Prueba 12: parametros incorrectos no provocan una caida del bot.
  test "bot rechaza dificultad y tiempo invalidos" do
    assert {:error, _} = Bot.decidir(pregunta_valida(), "medio", 10)
    assert {:error, _} = Bot.decidir(pregunta_valida(), "facil", 0)
    assert {:error, _} = Bot.decidir(%{}, "facil", 10)
  end

  # Prueba 13: persistencia rechaza datos incorrectos sin escribir archivos.
  test "persistencia rechaza formatos de escritura invalidos" do
    assert {:error, _} = Persistencia.guardar_usuarios(%{})
    assert {:error, _} = Persistencia.guardar_resultado([])
  end

  defp pregunta_valida do
    %{
      "tema" => "ciencia",
      "nivel" => "basico",
      "enunciado" => "Pregunta de prueba?",
      "opciones" => %{"A" => "Uno", "B" => "Dos", "C" => "Tres", "D" => "Cuatro"},
      "respuesta" => "A"
    }
  end
end
