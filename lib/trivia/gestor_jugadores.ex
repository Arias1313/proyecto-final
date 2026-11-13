
defmodule Trivia.GestorJugadores do
  use GenServer

  alias Trivia.Persistencia

  # Inicia el proceso GestorJugadores
  def start_link(_) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  # Carga los usuarios al iniciar el proceso
  @impl true
  def init(_) do
    case Persistencia.cargar_usuarios() do
      {:ok, usuarios} ->
        estado = %{
          usuarios: usuarios,
          conectados: []
        }

        {:ok, estado}

      {:error, motivo} ->
        {:stop, motivo}
    end
  end

  # Solicita conectar o registrar un jugador
  def conectar(usuario, clave) do
    GenServer.call(__MODULE__, {:conectar, usuario, clave})
  end

  # Procesa la solicitud de conexion
  @impl true
  def handle_call({:conectar, usuario, clave}, _from, estado) do
    case validar_datos(usuario, clave) do
      :ok ->
        procesar_conexion(usuario, clave, estado)

      {:error, motivo} ->
        {:reply, {:error, motivo}, estado}
    end
  end

  # Valida el nombre y la contraseña
  defp validar_datos(usuario, clave) do
    cond do
      not is_binary(usuario) or String.trim(usuario) == "" ->
        {:error, "El usuario no puede estar vacio"}

      String.match?(usuario, ~r/\s/u) ->
        {:error, "El usuario no puede contener espacios"}

      String.starts_with?(usuario, "bot_") ->
        {:error, "El prefijo bot_ esta reservado"}

      not is_binary(clave) or clave == "" ->
        {:error, "La clave no puede estar vacia"}

      true ->
        :ok
    end
  end

  # Determina si el usuario existe o debe registrarse
  defp procesar_conexion(usuario, clave, estado) do
    encontrado =
      Enum.find(estado.usuarios, fn jugador ->
        jugador["usuario"] == usuario
      end)

    cond do
      usuario in estado.conectados ->
        {:reply, {:error, "El usuario ya tiene una sesion activa"}, estado}

      encontrado == nil ->
        registrar_nuevo(usuario, clave, estado)

      encontrado["clave"] != clave ->
        {:reply, {:error, "Clave incorrecta"}, estado}

      true ->
        nuevo_estado = %{
          estado |
          conectados: [usuario | estado.conectados]
        }

        {:reply, {:ok, "Sesion iniciada correctamente"}, nuevo_estado}
    end
  end

  # Registra automaticamente al usuario nuevo
  defp registrar_nuevo(usuario, clave, estado) do
    nuevo_usuario = %{
      "usuario" => usuario,
      "clave" => clave
    }

    nuevos_usuarios = estado.usuarios ++ [nuevo_usuario]

    case Persistencia.guardar_usuarios(nuevos_usuarios) do
      {:ok, _} ->
        nuevo_estado = %{
          estado |
          usuarios: nuevos_usuarios,
          conectados: [usuario | estado.conectados]
        }

        {:reply, {:ok, "Usuario registrado y conectado"}, nuevo_estado}

      {:error, motivo} ->
        {:reply, {:error, motivo}, estado}
    end
  end

  # Solicita cerrar la sesion
  def cerrar_sesion(usuario) do
    GenServer.call(__MODULE__, {:cerrar_sesion, usuario})
  end

  # Procesa el cierre de sesion
  @impl true
  def handle_call({:cerrar_sesion, usuario}, _from, estado) do
    if usuario in estado.conectados do
      nuevos_conectados = List.delete(estado.conectados, usuario)

      nuevo_estado = %{
        estado |
        conectados: nuevos_conectados
      }

      {:reply, {:ok, "Sesion cerrada correctamente"}, nuevo_estado}
    else
      {:reply, {:error, "El usuario no tiene una sesion activa"}, estado}
    end
  end

  # Consulta los usuarios registrados
  def listar_usuarios do
    GenServer.call(__MODULE__, :listar_usuarios)
  end

  @impl true
  def handle_call(:listar_usuarios, _from, estado) do
    {:reply, {:ok, estado.usuarios}, estado}
  end

  # Consulta los jugadores conectados
  def listar_conectados do
    GenServer.call(__MODULE__, :listar_conectados)
  end

  @impl true
  def handle_call(:listar_conectados, _from, estado) do
    {:reply, {:ok, estado.conectados}, estado}
  end

end
