
defmodule Trivia.Persistencia do
  use GenServer

  # Archivos que utilizaremos para guardar la informacion
  @ruta_usuarios "data/users.json"
  @ruta_resultados "data/results.log"

  # ============================================================
  # INICIO DEL GENSERVER
  # ============================================================

  # Inicia el proceso encargado de las escrituras
  def start_link(_) do
    GenServer.start_link(
      __MODULE__,
      %{},
      name: __MODULE__
    )
  end

  # Estado inicial del proceso
  @impl true
  def init(estado) do
    {:ok, estado}
  end

  # ============================================================
  # FUNCIONES PUBLICAS PARA GUARDAR INFORMACION
  # ============================================================

  # Envia la lista de usuarios al GenServer
  def guardar_usuarios(usuarios) when is_list(usuarios) do
    GenServer.call(
      __MODULE__,
      {:guardar_usuarios, usuarios}
    )
  end

  # Rechaza datos que no sean listas
  def guardar_usuarios(_) do
    {:error, "Los usuarios deben estar en una lista"}
  end

  # Envia un resultado al GenServer
  def guardar_resultado(resultado) when is_map(resultado) do
    GenServer.call(
      __MODULE__,
      {:guardar_resultado, resultado}
    )
  end

  # Rechaza resultados que no sean mapas
  def guardar_resultado(_) do
    {:error, "El resultado debe ser un mapa"}
  end

  # ============================================================
  # SOLICITUDES RECIBIDAS POR EL GENSERVER
  # ============================================================

  # Procesa una solicitud para guardar usuarios
  @impl true
  def handle_call({:guardar_usuarios, usuarios}, _from, estado) do
    respuesta = escribir_usuarios(usuarios)
    {:reply, respuesta, estado}
  end

  # Procesa una solicitud para guardar un resultado
  @impl true
  def handle_call({:guardar_resultado, resultado}, _from, estado) do
    respuesta = escribir_resultado(resultado)
    {:reply, respuesta, estado}
  end

  # ============================================================
  # LECTURA Y ESCRITURA DE USUARIOS
  # ============================================================

  # Lee los usuarios registrados
  def cargar_usuarios do
    case File.read(@ruta_usuarios) do
      {:ok, contenido} ->
        case Jason.decode(contenido) do
          {:ok, usuarios} when is_list(usuarios) ->
            {:ok, usuarios}

          {:ok, _} ->
            {:error, "El archivo de usuarios debe contener una lista"}

          {:error, _} ->
            {:error, "El archivo de usuarios tiene un JSON incorrecto"}
        end

      {:error, motivo} ->
        {:error, "No se pudo leer usuarios: #{inspect(motivo)}"}
    end
  end

  # Guarda la lista completa de usuarios
  # Es privada porque solo el GenServer debe utilizarla
  defp escribir_usuarios(usuarios) when is_list(usuarios) do
    case Jason.encode(usuarios, pretty: true) do
      {:ok, contenido} ->
        case File.write(@ruta_usuarios, contenido) do
          :ok ->
            {:ok, "Usuarios guardados correctamente"}

          {:error, motivo} ->
            {:error, "No se pudo guardar usuarios: #{inspect(motivo)}"}
        end

      {:error, motivo} ->
        {:error, "No se pudo convertir a JSON: #{inspect(motivo)}"}
    end
  end

  # ============================================================
  # LECTURA Y ESCRITURA DE RESULTADOS
  # ============================================================

  # Agrega un resultado al historial de partidas
  # Es privada para centralizar las escrituras
  defp escribir_resultado(resultado) when is_map(resultado) do
    case Jason.encode(resultado) do
      {:ok, contenido} ->
        case File.write(@ruta_resultados, contenido <> "\n", [:append]) do
          :ok ->
            {:ok, "Resultado guardado correctamente"}

          {:error, motivo} ->
            {:error, "No se pudo guardar resultado: #{inspect(motivo)}"}
        end

      {:error, motivo} ->
        {:error, "No se pudo convertir resultado: #{inspect(motivo)}"}
    end
  end

  # Lee todos los resultados almacenados
  def cargar_resultados do
    case File.read(@ruta_resultados) do
      {:ok, contenido} ->
        lineas = String.split(contenido, "\n", trim: true)
        convertir_resultados(lineas, [])

      {:error, motivo} ->
        {:error, "No se pudo leer resultados: #{inspect(motivo)}"}
    end
  end

  # Caso base: ya no quedan lineas por procesar
  defp convertir_resultados([], acumulado) do
    {:ok, Enum.reverse(acumulado)}
  end

  # Convierte cada linea JSON en un mapa
  defp convertir_resultados([linea | resto], acumulado) do
    case Jason.decode(linea) do
      {:ok, resultado} when is_map(resultado) ->
        convertir_resultados(resto, [resultado | acumulado])

      _ ->
        {:error, "El historial contiene un resultado invalido"}
    end
  end

  # ============================================================
  # LECTURA DEL HISTORIAL CON STREAMS
  # ============================================================

  # Lee el historial linea por linea usando Streams
  def leer_historial_stream do
    case File.exists?(@ruta_resultados) do
      true ->
        @ruta_resultados
        |> File.stream!([], :line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(&Jason.decode/1)
        |> Enum.reduce_while({:ok, []}, fn
          {:ok, resultado}, {:ok, acumulado} when is_map(resultado) ->
            {:cont, {:ok, [resultado | acumulado]}}

          _, _ ->
            {:halt, {:error, "El historial contiene una linea invalida"}}
        end)
        |> case do
          {:ok, resultados} ->
            {:ok, Enum.reverse(resultados)}

          error ->
            error
        end

      false ->
        {:ok, []}
    end
  end

  # ============================================================
  # ESTADISTICAS DE JUGADORES
  # ============================================================

  # Calcula el puntaje acumulado de un jugador en un tema
  def puntaje_por_tema(resultados, usuario, tema)
      when is_list(resultados) do

    Enum.reduce(resultados, 0, fn resultado, total ->
      if resultado["tema"] == tema and
         not String.starts_with?(usuario, "bot_") do

        puntajes = Map.get(resultado, "puntajes", %{})
        puntos = Map.get(puntajes, usuario, 0)

        if is_number(puntos) do
          total + puntos
        else
          total
        end
      else
        total
      end
    end)
  end

  # Cuenta cuantas partidas ha jugado un usuario
  def partidas_jugadas(resultados, usuario)
      when is_list(resultados) do

    if String.starts_with?(usuario, "bot_") do
      0
    else
      Enum.count(resultados, fn resultado ->
        puntajes = Map.get(resultado, "puntajes", %{})
        Map.has_key?(puntajes, usuario)
      end)
    end
  end

  # ============================================================
  # CONSULTAS DEL PUNTAJE Y NIVEL HISTORICO
  # ============================================================

  # Consulta el puntaje historico desde el archivo
  def consultar_puntaje(usuario, tema) do
    case leer_historial_stream() do
      {:ok, resultados} ->
        {:ok, puntaje_por_tema(resultados, usuario, tema)}

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  # Obtiene el nivel del jugador a partir de sus puntos
  def consultar_nivel(usuario, tema) do
    case consultar_puntaje(usuario, tema) do
      {:ok, puntos} ->
        {:ok, Trivia.Nivel.obtener_nivel(puntos)}

      {:error, motivo} ->
        {:error, motivo}
    end
  end
end
