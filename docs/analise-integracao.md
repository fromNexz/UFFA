# Infra Monitor UFFA — análise inicial

## Evidências disponíveis

- Checkout `fromNexz/UFFA` sem commits ou arquivos de aplicação na inspeção inicial.
- Pedido de reconstrução, `infra-monitor-integracao.md` e cópia SQL fornecidos pelo usuário.
- As versões `infra-monitor`, `infra-monitor-agent` e o código Lovable não foram fornecidos. Não é possível identificar regressões ou componentes reutilizáveis sem esses arquivos.
- O documento informa que o SQL já foi aplicado. Nenhuma migração foi executada.
- GET sem credenciais para `https://infro-monitor.lovable.app/api/public/agent-pull-config`: bloqueado pelo proxy com `Tunnel connection failed: 403 Forbidden`. Não é resposta HTTP do aplicativo e não confirma presença ou ausência da rota.
- PowerShell e Windows indisponíveis na máquina atual. Nenhuma instalação, operação remota ou teste Windows foi executado.

## Contratos confirmados apenas pela documentação

- `POST /api/public/admin/hosts`: cadastro; corpo e resposta não fornecidos.
- `POST /api/public/ingest`: coleta antiga; corpo e resposta não fornecidos.
- `GET /api/public/agent-pull-config`: retorna `ips`, `pending_commands`, `service`.
- `POST /api/public/agent-status`: recebe `ips` e `monitor`.
- `POST /api/public/agent-action-result`: recebe `command_id`, `result` (`ok` ou `error`) e `message` de até 2000 caracteres.
- Novos endpoints: `X-Host-Token` e `X-Host-Id`; alternativa documentada `X-Host-Agent`.
- `host_id` corresponde ao UUID de `hosts.id`; não há `loja_id`.

Nenhum contrato foi validado contra o aplicativo publicado. Não inventar payloads de cadastro, heartbeat ou ingestão.

## Incompatibilidades e riscos observados

1. **Frequências:** documentação anterior pede ciclo de 2 minutos; novo requisito pede coleta de métricas/IPs/processos de 60 minutos, poll de 1 minuto e heartbeat de 5 minutos. Exigir agendamentos independentes e timestamps distintos.
2. **Offline incorreto:** `tick_monitor_automation` transforma `monitor_status.is_running` em falso após 2 minutos sem atualização. Isso conflita com o novo heartbeat e confunde ausência de comunicação com processo parado. Alterar somente após inspecionar o código e histórico real; distinguir conectividade, estado observado e idade da observação.
3. **Contagem de falhas:** falhas de IP são contadas por amostra aceita. Com intervalo de uma hora, três falhas levam aproximadamente três horas. A automação também estima falhas a cada 120 segundos; precisa de regra temporal explícita antes de mudar os intervalos.
4. **Entrega de comandos:** `claim_agent_commands` muda pending para dispatched, mas não retorna comandos já dispatched. Se a resposta de pull se perder, a execução pode nunca ocorrer e a tarefa expira. É necessário protocolo de reentrega/lease com deduplicação durável no agente.
5. **Garantia de execução:** registro local impede repetição de comandos conhecidos, mas uma queda entre o efeito no Windows e a gravação do resultado deixa resultado incerto. Persistir intenção antes da ação; após reinício, reconciliar estado e reportar incerteza sem repetir ações destrutivas cegamente. Não prometer execução exatamente uma vez em todos os cenários.
6. **Catálogo:** SQL limita comandos a quatro ações FrCaixaMonitor. Não atende catálogo genérico de aplicativos/serviços, configuração por alvo, operações permitidas e autorização de encerramento forçado.
7. **Encerramento forçado:** matar `monitor.exe` pelo nome pode atingir processos fora do alvo autorizado. Resolver PID e validar caminho/serviço local; não aceitar caminho do backend como autorização. Não aplicar fallback forçado automaticamente sem permissão local explícita.
8. **Autenticação:** o SQL não inclui validação dos headers, armazenamento dos tokens ou cadastro. É necessário analisar os handlers para verificar isolamento entre hosts e a origem do HTTP 406. Não trocar tokens por tentativa.
9. **NULL em funções SQL:** `complete_agent_command` e `queue_monitor_command` dependem de validação não nula pelos handlers. Condições SQL com NULL podem não entrar no ramo de rejeição; revisar validação da API e funções em conjunto. Não aplicar SQL sem histórico do banco.
10. **Observabilidade:** contrato de monitor não traz caminho do processo, horário de início, saúde funcional ou vários processos/serviços. IPs não trazem nome, descrição, protocolo ou intervalo. O frontend e o backend precisam de extensão compatível.
11. **Instalação e atualização:** faltam distribuição versionada, fonte e hash confiável do NSSM, configuração local, formatos legados e procedimentos de migração. Não inventar checksum ou interpretar token de proxy como segredo local utilizável.

## Pré-requisitos para a reconstrução

- Código integral das duas versões anteriores, incluindo instaladores, bootstrap, configurações de exemplo sem segredos e formato de identidade.
- Código Lovable correspondente aos endpoints, autenticação, ingestão, cadastro, frontend e histórico de migrações. Pode ser disponibilizado neste repositório ou como arquivos anexos.
- Confirmação da URL de homologação e acesso de rede ao domínio necessário.
- Para testes reais: Windows controlado e autorizado, host de teste e credenciais fornecidas por canal seguro. Nunca incluir tokens em chat ou no repositório.

## Sequência de implementação e validação

1. Mapear os fluxos antigos e os contratos completos a partir do código; preservar coleta e identidade existentes.
2. Implementar configuração única e catálogo local com ACLs; separar scheduler, cliente HTTPS, coleta, ações autorizadas, diário de comandos e resultados pendentes.
3. Adaptar backend/frontend para frequências independentes, conectividade, catálogo e reentrega sem executar novamente operações já conhecidas.
4. Implementar instalador/atualizador com backup, verificações criptográficas, preservação de identidade e rollback; NSSM permanente e serviço automático.
5. Testar contratos, 401/403/404/406/500, reconexão, isolamento por host e deduplicação com backend simulado, identificando explicitamente esses testes como simulação.
6. Em Windows de homologação, testar instalação, migração, métricas, IPs, operações permitidas, reboot, atualização e rollback. Só então validar integração publicada e alertas Teams.

## Estado

Análise documental concluída. Reconstrução e testes de integração permanecem bloqueados pelo código ausente e pelo acesso de rede. Nenhuma funcionalidade foi declarada validada.

## Decisão posterior e implementação v2

O usuário autorizou reconstrução completa sem os fontes anteriores. Portanto, a ausência desses fontes deixou de bloquear a implementação nova; continua impedindo comprovar compatibilidade com detalhes antigos não documentados. A solicitação posterior definiu meta de RAM <50 MB e teto <100 MB. O runtime foi alterado para C#/.NET Framework, com PowerShell apenas nas tarefas de instalação/administração.

A entrega v2 usa Edge Function nova, tabelas im_* aditivas e componente React. Não presume compatibilidade direta com ingest/cadastro antigos. Migração importa UUID e SHA256 do token sem modificar tabelas existentes. Novas lojas são criadas no painel novo. Ver README, contrato e relatório de validação atualizados. Nenhum arquivo antigo ou registro de produção foi alterado.
