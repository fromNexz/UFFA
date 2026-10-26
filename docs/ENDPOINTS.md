# Contrato v2 — a publicar

Base nova: `https://SEU-PROJETO.supabase.co/functions/v1/infra-monitor`. Estes endpoints estão implementados nos arquivos entregues, mas não foram publicados nem testados contra o projeto real. Não são declarações sobre as rotas antigas `/api/public/*`.

JSON UTF-8, `Accept: application/json`, `Content-Type: application/json` nos POSTs. HTTPS obrigatório no agente. Limite de corpo/resposta de 1 MiB. Sem redirects em chamadas autenticadas.

Agente: `X-Host-Id: UUID`, `X-Host-Token: token`. Sem `X-Host-Agent` alternativo no v2. Frontend: `Authorization: Bearer JWT_DO_USUARIO`, papel admin verificado no backend. O token de host nunca autoriza rotas administrativas.

| Método / sufixo | Uso |
|---|---|
| POST `enroll` | Código de uso único + request_id; retorna host_id/token |
| GET `agent-pull-config` | Intervalos, IPs habilitados e comandos válidos, com reentrega |
| POST `agent-heartbeat` | Presença e memória do agente; não renova data de métricas/processos |
| POST `ingest` | Snapshot completo de métricas v2 |
| POST `agent-status` | Snapshot de IPs OU processos, por kind |
| POST `agent-action-result` | Confirmação idempotente de comando |
| GET/POST `admin/hosts` | Listar/cadastrar; vínculo opcional com UUID antigo |
| POST `admin/enrollment` | Reemitir código somente para host sem token ativo |
| GET `admin/detail?host_id=UUID` | Host, IPs, últimas observações, comandos e auditoria |
| POST `admin/config` | Intervalos por host, em segundos |
| POST `admin/ips` | Criar/editar IP, nome, descrição, portas e enabled |
| POST `admin/commands` | Solicitar operação autorizada com motivo |

## Cadastro

```json
{"code":"CODIGO_64_HEX","request_id":"UUID"}
```

Resposta: `{"schema_version":2,"host_id":"UUID","token":"TOKEN_64_HEX"}`. Retry deve usar mesmo código e request_id; janela de recuperação de resposta perdida de 15 minutos após consumo. Token não sai em logs nem no painel.

## Configuração

```json
{"schema_version":2,"intervals":{"metrics":3600,"ips":3600,"processes":3600,"poll":60,"heartbeat":300},"ips":[{"ip":"10.0.0.5","tcp_ports":[80,443],"name":"Servidor","description":"","interval_seconds":null}],"pending_commands":[{"id":"UUID","host_id":"UUID","target_id":"frcaixa","operation":"restart","expires_at":"2026-10-24T12:10:00Z"}]}
```

Limites de intervalo: poll >=15s, heartbeat >=30s, demais >=60s, máximo 86400s. O catálogo NÃO vem desse endpoint. O caminho documentado na versão anterior não é usado como autorização.

## Heartbeat

```json
{"schema_version":2,"at":"2026-10-24T12:00:00Z","hostname":"MONITOR02","agent_version":"2.0.0","working_set_bytes":25000000,"private_bytes":18000000,"catalog":[{"id":"frcaixa","kind":"service","allowed_operations":["start","stop","restart"],"allow_force":false}]}
```

Servidor registra `last_seen_at=now()`, evitando depender do relógio da loja para conectividade. Datas de coleta permanecem separadas.

## Métricas

```json
{"schema_version":2,"observation_id":"UUID","metrics":{"collected_at":"2026-10-24T12:00:00Z","hostname":"MONITOR02","agent_version":"2.0.0","cpu_percent":10,"memory":{"total_bytes":8589934592,"available_bytes":4294967296,"used_percent":50},"uptime_seconds":3600,"disks":[{"name":"C:","total_bytes":100000000000,"free_bytes":50000000000}],"local_ips":["192.168.1.2"],"public_ip":null}}
```

IP público é null quando indisponível. Não consulta terceiros automaticamente.

## Status

IPs:

```json
{"schema_version":2,"observation_id":"UUID","kind":"ips","checked_at":"2026-10-24T12:00:00Z","ips":[{"ip":"10.0.0.5","is_up":true,"protocol":"tcp","checked_at":"2026-10-24T12:00:00Z"}]}
```

Processos:

```json
{"schema_version":2,"observation_id":"UUID","kind":"processes","checked_at":"2026-10-24T12:00:00Z","targets":[{"target_id":"frcaixa","kind":"service","service_name":"FrCaixaMonitor","is_running":true,"health":"unknown","checked_at":"2026-10-24T12:00:00Z","processes":[{"pid":1234,"executable":"C:\\FrCaixaMonitor\\monitor.exe","started_at":"2026-10-24T11:00:00Z","uptime_seconds":3600}]}]}
```

Erro local de catálogo/acesso: `is_running:null`, `health:"unknown"`, `error:"local_configuration_or_access_error"`, sem inventar que está parado. O backend deduplica observações por observation_id. Ao ficar offline, o agente mantém somente a última amostra pendente de cada tipo; isso limita disco e não promete histórico completo durante indisponibilidade.

## Comandos e resultado

Frontend solicita:

```json
{"host_id":"UUID","target_id":"frcaixa","operation":"restart","reason":"Recuperar após falha confirmada"}
```

Agente responde:

```json
{"command_id":"UUID","result":"ok","message":"Operação restart confirmada em frcaixa; saúde=unknown"}
```

Mensagem até 2000 caracteres. `ok` exige confirmação do estado; saúde unknown é informada explicitamente. Resultado idêntico repetido é aceito sem duplicar auditoria; divergente recebe 409. Resultado tardio de comando expirado é registrado sem gerar outra execução.

Diário local persiste intenção antes da ação. Depois de falha entre ação e gravação, retorna erro de resultado incerto e NÃO repete a operação. Exatamente uma execução com resultado garantido em qualquer queda não é promessa deste sistema.

## Erros

401: identidade/código/sessão rejeitados; 403: usuário/origem proibidos; 404: rota/host inexistentes; 406: schema incompatível; 409: conflito, comando ativo ou conclusão divergente; 400: payload inválido; 413: corpo excedido; 415: content type; 500: erro interno; 503: enrollment não configurado.

O agente repete apenas erros de rede, 429 e 5xx, com tentativas limitadas. 401/403/404/406 exigem diagnóstico, não substituição automática de token. Logs usam códigos de evento, sem corpos HTTP ou cabeçalhos secretos.

IPs podem definir `interval_seconds` entre 60 e 86400; null usa o intervalo da loja. Datas individuais acompanham cada destino; mudar configuração não provoca novos testes antes do prazo de um destino já coletado.
