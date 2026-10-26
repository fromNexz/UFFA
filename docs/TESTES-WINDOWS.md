# Homologação Windows — não executada nesta máquina

Usar servidor de teste, conta administrativa autorizada e loja de homologação. Não executar operações de controle nas lojas de produção para testar. Registrar versão, SO, .NET, evidências e cada resultado; não preencher como aprovado antes de executar.

| Cenário | Procedimento / aprovação |
|---|---|
| Instalação limpa | Pacote verificado, cadastro único, serviço automático, heartbeat em até 90s, nenhum admin token persistido |
| Permissões | Usuário comum não lê identity.json nem backups; somente SYSTEM/Administradores acessam; serviço não pode ser reconfigurado por usuário comum |
| Migração | Registrar UUID/hash antes e depois; devem coincidir. Antigo diretório intacto e backup legível por administrador; antigo serviço só desativado após sucesso |
| Serviço com mesmo nome | Piloto com InfraMonitorAgent antigo LocalSystem: caminho SCM alterado corretamente; falha simulada restaura caminho e modo anteriores |
| Bootstrap | Código válido; repetir mesmo request após perda da resposta retorna a mesma identidade; request diferente/código expirado recusados |
| Autenticação | Sem token/errado recebe 401; usuário sem admin recebe 403 em rotas administrativas; host B não conclui comando do A |
| Heartbeat | Comparar last_seen com horário do servidor; não altera last_metrics/last_ips/last_processes |
| CPU/RAM/discos | Comparar snapshot com WMI/gerenciador de tarefas, tolerando variação; uptime plausível e discos locais corretos |
| IPs | ICMP permitido/bloqueado, TCP aberto/fechado e duas portas com apenas uma aberta; todas configuradas precisam responder |
| Intervalos | Nenhuma coleta completa repetida a cada poll. Alterar valores na homologação e verificar agendamentos independentes |
| FrCaixaMonitor | Confirmar nome/caminho real; PID/início/uptime. Processo ativo sem sonda configurada deve exibir saúde desconhecida |
| Saúde funcional | Configurar porta local de teste; porta falhando com processo ativo deve ficar unhealthy, não parado |
| Catálogo | Caminho divergente, serviço ambíguo, alvo desconhecido e operação não permitida recusados, sem iniciar binário recebido da API |
| Ações | Start/stop/restart em serviço descartável autorizado. Confirmar SCM e estado final. kill só com permissão local dupla explícita |
| Idempotência | Reentregar mesmo ID várias vezes: ação uma vez, confirmações repetidas aceitas; uma auditoria de conclusão |
| Queda durante ação | Encerrar agente entre intenção e conclusão em ambiente isolado: resultado incerto ao reiniciar, sem repetição destrutiva |
| Internet indisponível | Bloquear SOMENTE domínio de homologação por mecanismo de teste reversível. Últimos snapshots preservados; confirmações reenviadas após restauração; sem duplicar ações |
| Reinício Windows | Serviço automático volta; UUID/token iguais; diário sobrevive; nenhum comando concluído executa de novo |
| Atualização | Release superior, backup, configuração/token/diário iguais, novo heartbeat confirma versão |
| Rollback | Release de teste que falha no heartbeat: restaurar executável/scripts anteriores; heartbeat antigo confirmado; não restaurar diário velho |
| HTTP 406 | Backend de homologação rejeita schema: log poll_contract_not_acceptable, sem troca de token ou cadastro novo |
| RAM/CPU | 65 minutos incluindo coleta e comando, working set e privados <100 MB, preferencial <50 MB, contando NSSM; nenhum ciclo contínuo de reinício |
| Lovable | Fluxos admin, edição IPs, intervalos, timestamps antigos destacados, fila e auditoria reais |
| Alertas antigos | Hosts vinculados não geram falso offline pelo cron de 2 minutos antigo. Teams só aprovado após entrega real |

Executar `scripts/Measure-Agent.ps1` e guardar CSV com relatório do SO. Complementar com PerfMon para picos curtos. Testar tamanho de catálogo/lista de IPs semelhante à loja com maior carga. Não transformar uma falha em aprovado reduzindo a quantidade de alvos de forma irreal.

## Diagnóstico HTTP

Consultar `logs\agent.log`, logs da Edge Function e status do deploy. Não registrar headers ou corpo de enrollment. 406 v2 identifica schema incompatível; isso não diagnostica o 406 antigo, cujo código/logs não foram fornecidos. 404 pode ser base URL, route ou host ausente; 401 não implica necessidade de token novo. Conferir primeiro UUID, URL, deploy, hash importado e versão.

## Recuperação manual

Em falha de atualização, o script tenta rollback e valida heartbeat antigo. Se falhar também, manter serviço parado até inspeção e restaurar pacote aprovado; não apagar identity.json/diário. Em falha de migração, confirmar serviço antigo ativo e caminho SCM original; a cópia antiga continua intacta. Não aplicar SQL novamente para resolver autenticação.
