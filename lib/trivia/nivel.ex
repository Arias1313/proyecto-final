
defmodule Trivia.Nivel do

  # Determina el nivel segun el puntaje acumulado
  def obtener_nivel(puntaje) when is_number(puntaje) do
    cond do
      puntaje < 60 -> "basico"
      puntaje < 180 -> "intermedio"
      true -> "avanzado"
    end
  end

  def obtener_nivel(_) do
    {:error, "Puntaje invalido"}
  end

  # Calcula cuantas preguntas corresponden a cada nivel
  def distribuir_preguntas(nivel, total)
      when is_integer(total) and total > 0 do

    case nivel do
      "basico" ->
        intermedias = trunc(total * 30 / 100)

        %{
          basico: total - intermedias,
          intermedio: intermedias,
          avanzado: 0
        }

      "intermedio" ->
        basicas = trunc(total * 20 / 100)
        avanzadas = trunc(total * 20 / 100)

        %{
          basico: basicas,
          intermedio: total - basicas - avanzadas,
          avanzado: avanzadas
        }

      "avanzado" ->
        intermedias = trunc(total * 30 / 100)

        %{
          basico: 0,
          intermedio: intermedias,
          avanzado: total - intermedias
        }

      _ ->
        {:error, "Nivel no permitido"}
    end
  end

  def distribuir_preguntas(_, _) do
    {:error, "Cantidad invalida"}
  end

end
