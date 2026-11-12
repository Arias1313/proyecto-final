
defmodule Trivia.Persistencia do

  # Archivos que utilizaremos para guardar la informacion
  @ruta_usuarios "data/users.json"
  @ruta_resultados "data/results.log"

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
  def guardar_usuarios(usuarios) when is_list(usuarios) do
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

  def guardar_usuarios(_) do
    {:error, "Los usuarios deben estar en una lista"}
  end

  # Agrega un resultado al historial de partidas
  def guardar_resultado(resultado) when is_map(resultado) do
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

  def guardar_resultado(_) do
    {:error, "El resultado debe ser un mapa"}
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

end
