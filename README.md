# ProyectoTrivia

comando para iniciar el servidor 

Terminal 1. 
Servidor
$env:TRIVIA_ROL = "servidor"
iex.bat --sname servidor -S mix

Terminal 2.
 Cliente
$env:TRIVIA_ROL = "cliente"
iex.bat --sname cliente1 -S mix

Terminal 3.
$env:TRIVIA_ROL = "cliente"
iex.bat --sname cliente2 -S mix


Desde IEx ejecuta:

Node.connect(:"servidor@nombre_pc")

Trivia.Cliente.iniciar(:"servidor@nombre_pc")
