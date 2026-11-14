
defmodule Trivia.BancoPreguntas do

  # Ruta donde se encuentra el banco de preguntas
  @ruta "data/questions.json"

  use GenServer

  # El servidor lee el archivo una sola vez durante el arranque.
  # Los clientes no inician este proceso ni tienen acceso al archivo.
  def start_link(_) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    case leer_archivo() do
      {:ok, preguntas} ->
        case revisar_banco(preguntas) do
          {:ok, _} -> {:ok, preguntas}
          {:error, errores} -> {:stop, {:banco_invalido, errores}}
        end
      {:error, motivo} -> {:stop, {:banco_invalido, motivo}}
    end
  end

  # API publica: devuelve la copia de las preguntas almacenadas en memoria.
  def cargar_preguntas, do: GenServer.call(__MODULE__, :cargar_preguntas)

  @impl true
  def handle_call(:cargar_preguntas, _from, preguntas) do
    {:reply, {:ok, preguntas}, preguntas}
  end

  # Devuelve los temas reales del banco, sin tener una lista fija.
  def temas_disponibles, do: GenServer.call(__MODULE__, :temas_disponibles)

  @impl true
  def handle_call(:temas_disponibles, _from, preguntas) do
    temas = preguntas |> Enum.map(& &1["tema"]) |> Enum.uniq() |> Enum.sort()
    {:reply, {:ok, temas}, preguntas}
  end

  # Esta funcion privada es la unica que abre questions.json.
  defp leer_archivo do
    case File.read(@ruta) do
      {:ok, contenido} ->
        case Jason.decode(contenido) do
          {:ok, preguntas} when is_list(preguntas) -> {:ok, preguntas}
          {:ok, _} -> {:error, "El banco debe contener una lista de preguntas"}
          {:error, _} -> {:error, "El archivo JSON tiene un formato incorrecto"}
        end
      {:error, _} -> {:error, "No se pudo leer el archivo de preguntas"}
    end
  end

  # Busca las preguntas que pertenecen a un tema
  def preguntas_por_tema(tema) do
    case cargar_preguntas() do
      {:ok, preguntas} ->
        filtradas =
          Enum.filter(preguntas, fn pregunta ->
            pregunta["tema"] == tema
          end)

        {:ok, filtradas}

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  # Busca preguntas de un tema y un nivel
  def preguntas_por_nivel(tema, nivel) do
    case preguntas_por_tema(tema) do
      {:ok, preguntas} ->
        filtradas =
          Enum.filter(preguntas, fn pregunta ->
            pregunta["nivel"] == nivel
          end)

        {:ok, filtradas}

      {:error, motivo} ->
        {:error, motivo}
    end
  end


  # Temas y niveles permitidos
  @niveles ["basico", "intermedio", "avanzado"]
  @opciones ["A", "B", "C", "D"]

  # Comprueba que una pregunta tenga todos sus datos
  def validar_pregunta(pregunta) when is_map(pregunta) do
    tema = pregunta["tema"]
    nivel = pregunta["nivel"]
    enunciado = pregunta["enunciado"]
    opciones = pregunta["opciones"]
    respuesta = pregunta["respuesta"]

    cond do
      not is_binary(tema) or not Regex.match?(~r/^[a-z][a-z0-9_]*$/, tema) ->
        {:error, "Tema no permitido"}

      nivel not in @niveles ->
        {:error, "Nivel no permitido"}

      not is_binary(enunciado) or String.trim(enunciado) == "" ->
        {:error, "La pregunta no tiene un enunciado valido"}

      not is_map(opciones) ->
        {:error, "Las opciones no tienen el formato correcto"}

      Enum.sort(Map.keys(opciones)) != @opciones ->
        {:error, "La pregunta debe tener las opciones A, B, C y D"}

      Enum.any?(Map.values(opciones), fn opcion ->
        not is_binary(opcion) or String.trim(opcion) == ""
      end) ->
        {:error, "Las opciones no pueden estar vacias"}

      respuesta not in @opciones ->
        {:error, "La respuesta correcta no es valida"}

      true ->
        {:ok, pregunta}
    end
  end

  def validar_pregunta(_) do
    {:error, "La pregunta debe ser un mapa"}
  end

  # Comprueba que todas las preguntas sean validas
  def validar_banco do
    case cargar_preguntas() do
      {:ok, preguntas} -> revisar_banco(preguntas)
      {:error, motivo} -> {:error, motivo}
    end
  end

  defp revisar_banco(preguntas) do
    errores =
      preguntas
      |> Enum.with_index(1)
      |> Enum.reduce([], fn {pregunta, numero}, acumulado ->
        case validar_pregunta(pregunta) do
          {:ok, _} ->
            acumulado

          {:error, motivo} ->
            ["Pregunta #{numero}: #{motivo}" | acumulado]
        end
      end)

    if errores != [] do
      {:error, Enum.reverse(errores)}
    else
      verificar_cantidades(preguntas)
    end
  end

  # Comprueba que existan 8 preguntas por tema y nivel
  defp verificar_cantidades(preguntas) do
    temas = preguntas |> Enum.map(& &1["tema"]) |> Enum.uniq()

    errores =
      for tema <- temas,
          nivel <- @niveles,
          reduce: [] do
        acumulado ->
          cantidad =
            Enum.count(preguntas, fn pregunta ->
              pregunta["tema"] == tema and
                pregunta["nivel"] == nivel
            end)

          if cantidad < 8 do
            ["#{tema} - #{nivel}: solo hay #{cantidad} preguntas" | acumulado]
          else
            acumulado
          end
      end

    enunciados =
      Enum.map(preguntas, fn pregunta ->
        String.downcase(String.trim(pregunta["enunciado"]))
      end)

    repetidas = length(enunciados) != length(Enum.uniq(enunciados))

    cond do
      length(temas) < 4 ->
        {:error, ["El banco debe contener al menos 4 temas"]}

      errores != [] ->
        {:error, Enum.reverse(errores)}

      repetidas ->
        {:error, ["Hay preguntas repetidas en el banco"]}

      true ->
        {:ok, "Banco de preguntas valido"}
    end
  end


  # Selecciona preguntas aleatorias sin repetir
  def seleccionar_preguntas(tema, nivel, cantidad)
      when is_integer(cantidad) and cantidad > 0 do

    case preguntas_por_nivel(tema, nivel) do
      {:ok, preguntas} ->
        if length(preguntas) >= cantidad do
          seleccionadas =
            preguntas
            |> Enum.shuffle()
            |> Enum.take(cantidad)

          {:ok, seleccionadas}
        else
          {:error, "No hay suficientes preguntas disponibles"}
        end

      {:error, motivo} ->
        {:error, motivo}
    end
  end

  # Maneja cantidades incorrectas
  def seleccionar_preguntas(_, _, _) do
    {:error, "La cantidad debe ser un entero positivo"}
  end


  # Selecciona las preguntas segun el nivel del jugador
  def preparar_preguntas(tema, nivel, cantidad) do
    case Trivia.Nivel.distribuir_preguntas(nivel, cantidad) do
      {:error, motivo} ->
        {:error, motivo}

      distribucion ->
        niveles = [
          {"basico", distribucion.basico},
          {"intermedio", distribucion.intermedio},
          {"avanzado", distribucion.avanzado}
        ]

        seleccionar_por_niveles(tema, niveles, [])
    end
  end

  # Caso base: terminamos de procesar los niveles
  defp seleccionar_por_niveles(_tema, [], acumulado) do
    {:ok, acumulado}
  end

  # Selecciona preguntas del nivel correspondiente
  defp seleccionar_por_niveles(
         tema, [{nivel, cantidad} | resto], acumulado
       ) do

    if cantidad == 0 do
      seleccionar_por_niveles(tema, resto, acumulado)
    else
      case seleccionar_preguntas(tema, nivel, cantidad) do
        {:ok, preguntas} ->
          seleccionar_por_niveles(
            tema,
            resto,
            acumulado ++ preguntas
          )

        {:error, motivo} ->
          {:error, "#{nivel}: #{motivo}"}
      end
    end
  end


  # Prepara preguntas segun los puntos historicos
  def preparar_para_jugador(usuario, tema, cantidad) do
    case Trivia.Persistencia.consultar_nivel(usuario, tema) do
      {:ok, nivel} ->
        preparar_preguntas(tema, nivel, cantidad)

      {:error, motivo} ->
        {:error, motivo}
    end
  end





end
