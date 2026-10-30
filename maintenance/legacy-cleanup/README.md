# Remoção do agente antigo

Executar `Remover-InfraMonitor-Antigo.ps1 -Aplicar` como administrador, ou usar o comando RAW com hash fornecido na entrega. Sem `-Aplicar`, apenas inventaria componentes reconhecidos.

Identifica scripts antigos em `C:\infra-monitor` e `C:\ProgramData\InfraMonitor`, serviço via CMD/PowerShell/NSSM e tarefas do coletor/watchdog/relançamento. Faz backup protegido da configuração de inicialização antes de desativá-la e encerra somente processos identificados pelo script e caminho. Mantém arquivos, credenciais, FrCaixaMonitor/monitor.exe e a instalação nova em `C:\infra-monitor-unificado`. Não acessa nem limpa o Lovable.

A finalidade do FrCaixaMonitor no projeto é somente monitoramento. Nunca parar, reiniciar, remover ou encerrar o aplicativo ERP/PDV durante esta limpeza.

Validação: `pwsh -NoProfile -File Testar-Regras.ps1` executa 29 testes das regras. Remoção real e integração com Windows ainda precisam de piloto autorizado. Outras inicializações não presentes no ZIP analisado, como GPO/RMM ou comandos codificados, exigem inspeção separada.

O download RAW deve usar SHA de commit e SHA256 fixados; não executar texto remoto diretamente com Invoke-Expression.
