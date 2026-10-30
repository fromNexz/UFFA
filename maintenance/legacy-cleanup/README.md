# Remoção do agente antigo

Executar `Remover-InfraMonitor-Antigo.ps1 -Aplicar` como administrador, ou usar o comando RAW com hash fornecido na entrega. Sem `-Aplicar`, apenas inventaria componentes reconhecidos.

Identifica scripts antigos em `C:\infra-monitor` e `C:\ProgramData\InfraMonitor`, serviço via CMD/PowerShell/NSSM e tarefas do coletor/watchdog/relançamento. Faz backup protegido da configuração de inicialização antes de desativá-la e encerra somente processos identificados pelo script e caminho. Mantém arquivos, credenciais, FrCaixaMonitor/monitor.exe e a instalação nova em `C:\infra-monitor-unificado`. Não acessa nem limpa o Lovable.

A finalidade do FrCaixaMonitor no projeto é somente monitoramento. Nunca parar, reiniciar, remover ou encerrar o aplicativo ERP/PDV durante esta limpeza.

Validação: `pwsh -NoProfile -File Testar-Regras.ps1` executa 29 testes das regras. Remoção real e integração com Windows ainda precisam de piloto autorizado. Outras inicializações não presentes no ZIP analisado, como GPO/RMM ou comandos codificados, exigem inspeção separada.

O download RAW deve usar SHA de commit e SHA256 fixados; não executar texto remoto diretamente com Invoke-Expression.

## Atualização: retirar também C:\infra-monitor

O RAW atualizado, com `-Aplicar`, retira também **somente** `C:\infra-monitor`. Funciona mesmo se o serviço já tiver sido removido. Após confirmar que não restam componentes antigos reconhecidos, confere serviços, tarefas e processos que ainda usem esse caminho, salva as ACLs e move o conteúdo integral para `C:\ProgramData\InfraMonitor-Remocao-DATA-ID\infra-monitor`, com acesso somente a SYSTEM/Administradores. Assim o caminho original deixa de existir sem descartar a cópia de recuperação. Não promete liberar espaço em disco.

Diretórios FrCaixa, arquivo `monitor.exe`, links/junctions ou referências restantes impedem a retirada. Não remove `C:\ProgramData\InfraMonitor` nem `C:\infra-monitor-unificado`. Se houver arquivo em uso ou serviço marcado para exclusão, a etapa falha e informa o motivo; não força exclusão do ERP. Uma política externa que recrie a pasta/agente deve ser tratada separadamente.

44 testes das regras e da inspeção segura de árvores passaram no Linux/PowerShell 7. Movimentação/ACLs e serviços Windows precisam de piloto. O script não substitui os comandos RAW antigos fixados por commit; usar a nova URL e o novo hash da entrega.
