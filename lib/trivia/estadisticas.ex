defmodule Trivia.Estadisticas do
  @moduledoc """
  Calcula las estadisticas exclusivamente a partir de results.log.
  No guarda puntos duplicados en users.json.
  """

  alias Trivia.Persistencia
  alias Trivia.Nivel

  # Lee el historial existente. Si aun no hay partidas, el historial es vacio.
  def score(usuario) when is_binary(usuario) do
    case Persistencia.leer_historial_stream() do
      {:ok, resultados} ->
        # Solo se cuentan los resultados donde participo el usuario.
        partidas = Persistencia.partidas_jugadas(resultados, usuario)

        temas =
          resultados
          |> Enum.filter(fn resultado ->
            Map.has_key?(Map.get(resultado, "puntajes", %{}), usuario)
          end)
          |> Enum.map(& &1["tema"])
          |> Enum.filter(&is_binary/1)
          |> Enum.uniq()
          |> Enum.sort()

        por_tema = Enum.map(temas, fn tema ->
          puntos = Persistencia.puntaje_por_tema(resultados, usuario, tema)
          %{tema: tema, puntos: puntos, nivel: Nivel.obtener_nivel(puntos)}
        end)

        total = Enum.reduce(por_tema, 0, fn dato, acumulado ->
          acumulado + dato.puntos
        end)

        {:ok, %{usuario: usuario, total: total, partidas: partidas, temas: por_tema}}

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  # nil significa ranking global; un string indica un tema especifico.
  def ranking(tema \\ nil)

  def ranking(tema) when is_nil(tema) or is_binary(tema) do
    case Persistencia.leer_historial_stream() do
      {:ok, resultados} ->
        # Se filtran partidas por tema antes de sumar puntos y participaciones.
        filtrados =
          if tema == nil do
            resultados
          else
            Enum.filter(resultados, fn resultado -> resultado["tema"] == tema end)
          end

        # Las claves del mapa de puntajes son los nombres de los participantes.
        # El prefijo bot_ esta reservado: se excluye del ranking historico.
        ranking =
          Enum.reduce(filtrados, %{}, fn resultado, acumulado ->
            puntajes = Map.get(resultado, "puntajes", %{})

            Enum.reduce(puntajes, acumulado, fn {usuario, puntos}, tabla ->
              if is_binary(usuario) and not String.starts_with?(usuario, "bot_") and
                   is_number(puntos) do
                Map.update(tabla, usuario, %{usuario: usuario, puntos: puntos, partidas: 1},
                  fn anterior ->
                    %{anterior | puntos: anterior.puntos + puntos,
                                 partidas: anterior.partidas + 1}
                  end)
              else
                tabla
              end
            end)
          end)
          |> Map.values()
          |> Enum.sort_by(fn jugador -> {-jugador.puntos, jugador.usuario} end)

        {:ok, ranking}

      {:error, motivo} ->
        {:error, motivo}
    end
  end
end
