
defmodule Trivia.GestorJugadores do

  use GenServer

  alias Trivia.Persistencia

  # Inicia el proceso que administra los jugadores
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

  # Solicita registrar un nuevo usuario
  def registrar(usuario) do
    GenServer.call(__MODULE__, {:registrar, usuario})
  end

  # Procesa el registro
  @impl true
  def handle_call({:registrar, usuario}, _from, estado) do
    cond do
      not is_binary(usuario) ->
        {:reply, {:error, "El usuario debe ser un texto"}, estado}

      String.trim(usuario) == "" ->
        {:reply, {:error, "El usuario no puede estar vacio"}, estado}

      usuario_existente?(estado.usuarios, usuario) ->
        {:reply, {:error, "El usuario ya esta registrado"}, estado}

      true ->
        nuevo_usuario = %{"usuario" => usuario}
        nuevos_usuarios = estado.usuarios ++ [nuevo_usuario]

        case Persistencia.guardar_usuarios(nuevos_usuarios) do
          {:ok, _} ->
            nuevo_estado = %{estado | usuarios: nuevos_usuarios}

            {:reply, {:ok, "Usuario registrado correctamente"}, nuevo_estado}

          {:error, motivo} ->
            {:reply, {:error, motivo}, estado}
        end
    end
  end

  # Comprueba si un usuario ya existe
  defp usuario_existente?(usuarios, nombre) do
    Enum.any?(usuarios, fn usuario ->
      usuario["usuario"] == nombre
    end)
  end

  # Solicita iniciar sesion
  def iniciar_sesion(usuario) do
    GenServer.call(__MODULE__, {:iniciar_sesion, usuario})
  end

  # Procesa el inicio de sesion
  @impl true
  def handle_call({:iniciar_sesion, usuario}, _from, estado) do
    cond do
      not usuario_existente?(estado.usuarios, usuario) ->
        {:reply, {:error, "El usuario no esta registrado"}, estado}

      usuario in estado.conectados ->
        {:reply, {:error, "El usuario ya tiene una sesion activa"}, estado}

      true ->
        nuevos_conectados = [usuario | estado.conectados]
        nuevo_estado = %{estado | conectados: nuevos_conectados}

        {:reply, {:ok, "Sesion iniciada correctamente"}, nuevo_estado}
    end
  end

  # Solicita cerrar sesion
  def cerrar_sesion(usuario) do
    GenServer.call(__MODULE__, {:cerrar_sesion, usuario})
  end

  # Procesa el cierre de sesion
  @impl true
  def handle_call({:cerrar_sesion, usuario}, _from, estado) do
    if usuario in estado.conectados do
      nuevos_conectados = List.delete(estado.conectados, usuario)
      nuevo_estado = %{estado | conectados: nuevos_conectados}

      {:reply, {:ok, "Sesion cerrada correctamente"}, nuevo_estado}
    else
      {:reply, {:error, "El usuario no tiene una sesion activa"}, estado}
    end
  end

  # Solicita la lista de usuarios registrados
  def listar_usuarios do
    GenServer.call(__MODULE__, :listar_usuarios)
  end

  @impl true
  def handle_call(:listar_usuarios, _from, estado) do
    {:reply, {:ok, estado.usuarios}, estado}
  end

  # Solicita la lista de jugadores conectados
  def listar_conectados do
    GenServer.call(__MODULE__, :listar_conectados)
  end

  @impl true
  def handle_call(:listar_conectados, _from, estado) do
    {:reply, {:ok, estado.conectados}, estado}
  end

end
