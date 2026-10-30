# Instalação via GitHub — 2.0.1

O iniciador `maintenance/Instalar-InfraMonitor-Web.ps1` baixa um pacote com commit e SHA256 fixados, confere arquivos/versão, identifica instalações anteriores e executa o instalador sem exigir download/extracão manual. Cole o comando publicado com hash em PowerShell como administrador; o único dado secreto solicitado é o código exclusivo da loja gerado no painel. Não colocar tokens/códigos no comando RAW.

- Destino: `C:\infra-monitor-unificado`; API padrão: `https://infro-monitor.lovable.app/api/public/infra-monitor`.
- Serviço antigo, tarefas/watchdog antigos ou processos reconhecidos bloqueiam a instalação nova. Usar a limpeza específica primeiro, sem mexer no ERP/PDV.
- Serviço novo já instalado: informa estado e não altera serviço, configuração ou identidade. Atualização de instalação existente é um procedimento separado (`Update.ps1`).
- Instalação parcial reconhecida: retoma a mesma identidade/cadastro pendente com `-Resume`, mantendo configuração de intervalos. A API deve coincidir; não muda credenciais por tentativa.
- Pasta de conteúdo desconhecido: preserva e interrompe, sem limpar automaticamente.
- Instalação nova: pede código, instala serviço automático e aguarda heartbeat; confirma somente se recebido pelo backend.
- O catálogo instalado observa `monitor.exe` por nome, reportando caminhos/PIDs/início das instâncias encontradas. Não inicia, para, reinicia ou mata o ERP. Não precisa presumir um caminho/local de serviço.
- As operações do catálogo ficam vazias; o runtime 2.0.1 também recusa controle do FrCaixaMonitor e do executável monitor.exe, mesmo que uma configuração antiga habilite ações.
- Demais intervalos e coletores continuam os existentes: métricas/IPs/processos horários, poll 60s e heartbeat 300s.

O pacote usa API v2 existente: publicar o backend e cadastrar cada loja no painel continua necessário. O frontend deve aceitar `kind=process` e `allowed_operations=[]`; esses campos já fazem parte do contrato entregue.

Relógio incorreto: a exceção `server_received` é uma adaptação feita no Lovable para o UUID correspondente, não é ativada globalmente nem embutida no agente. Um cadastro novo com relógio incorreto ainda precisa de política apropriada no backend. Não reinstalar ou trocar tokens para resolver HTTP 400. A versão 2.0.1 registra números HTTP, por exemplo `heartbeat_http_400_request_rejected`.

## Validação

27 testes do núcleo e 6 verificações de scripts passaram no Linux/PowerShell 7, incluindo bloqueios ERP/PDV e transformação de catálogo idempotente. Compilação C# 5 / .NET Framework 4.7.2 / x86 passou. 12 testes do iniciador web passaram nas decisões de instalação/retomada e validação de URL (45 cenários/verificações locais nesta atualização).

Serviço Windows, coleta WMI por nome, fluxo de cadastro real e memória <50 MB preferencial/<100 MB obrigatória ainda exigem loja piloto autorizada. O novo iniciador reduz etapas de instalação; não constitui prova de homologação no Windows.
