
defmodule Trivia.Receptor do

  # Inicia un proceso receptor
  def iniciar do
    spawn(fn -> escuchar() end)
  end

  # Espera mensajes enviados al proceso
  defp escuchar do
    receive do
      {:mensaje, texto} ->
        IO.puts("\n[Servidor] #{texto}")
        escuchar()

      {:pregunta, pregunta} ->
        IO.puts("\n===== NUEVA PREGUNTA =====")
        IO.puts(pregunta["enunciado"])

        Enum.each(["A", "B", "C", "D"], fn opcion ->
          texto = pregunta["opciones"][opcion]
          IO.puts("#{opcion}. #{texto}")
        end)

        escuchar()

      :detener ->
        :ok

      otro ->
        IO.inspect(otro, label: "Mensaje recibido")
        escuchar()
    end
  end
end
