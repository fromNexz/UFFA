# Atualizacao 2.2.1 — executavel ainda em uso

A 2.2.0 tentava copiar o executavel apos Stop-Service, sem confirmar a saida de todos os processos da instalacao nem a liberacao da imagem. Isso pode falhar com "arquivo esta sendo usado por outro processo", mesmo depois de o SCM indicar Stopped.

O atualizador agora solicita a parada do servico, aguarda ate 15 segundos pela saida normal e verifica tanto o estado do SCM quanto os processos e acesso exclusivo aos binarios. Se persistirem, encerra somente `InfraMonitor.Agent.exe` e `InfraMonitor.UserTask.exe` cujo caminho seja exatamente `bin` da raiz autorizada. O objeto Process e mantido com handle aberto; antes de Kill, caminho, PID e horario de criacao sao revalidados para evitar atingir PID reutilizado. A saida e aguardada ate 5s por processo, seguida de ate 15s para confirmar liberacao. Processos que ja sairam dispensam Kill.

Nao usa taskkill por nome nem encerra FrCaixaMonitor, monitor.exe, RustDesk ou agentes de outras pastas. Se um processo for recriado externamente ou o arquivo continuar bloqueado, interrompe a substituicao. Nao entra em ciclo de encerramentos forcados.

O mesmo auxiliar e usado antes de copiar o backup no rollback. Se somente a parada foi iniciada e nenhum arquivo foi substituido, a recuperacao reinicia a versao original sem copiar os binarios. O erro original e preservado; falha de recuperacao informa o caminho do backup e nao afirma heartbeat confirmado.

Execute `maintenance/COMANDO-ATUALIZAR-2.2.1.txt` em PowerShell como administrador. Use este novo comando, pois o anterior aponta para a release 2.2.0 imutavel. Atualiza diretamente da 2.1.0 para 2.2.1, preservando UUID/token/diario e mantendo o procedimento de migracao do catalogo existente.

14 testes de parada/identidade do processo passaram, incluindo arquivo realmente bloqueado numa fixture de teste; SCM e processos sao simulados no Linux. Instalador e atualizador foram analisados/testados, e agente/helper compilados para .NET Framework 4.7.2 x86. A parada real de um servico Windows e substituicao de uma imagem carregada precisam ser confirmadas na loja piloto.
