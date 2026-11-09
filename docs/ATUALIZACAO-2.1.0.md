# Agente 2.1.0 — manutenção remota

Esta versão implementa a nova autorização do usuário de 09/11/2026: controle explícito do FrCaixa, RustDesk e limpeza Windows. Isso substitui a política anterior de somente observar o ERP. A atualização não executa essas ações por si só; elas dependem de pedidos administrativos autenticados, direcionados ao host correto e autorizados no catálogo local.

## Atualizar sem reinstalar

Usar o comando RAW com SHA256 da entrega, apontando para `maintenance/Atualizar-InfraMonitor-Web.ps1`. O iniciador baixa pacote fixado por commit/hash e chama o atualizador novo com `-EnableRemoteMaintenance`. Ele não solicita código de cadastro nem recria UUID/token. O serviço do agente é reiniciado; o atualizador não envia pedidos nem chama ações de ERP/RustDesk. O agente novo pode consumir comandos administrativos válidos que já estejam na fila.

O catálogo local é migrado para os três targets obrigatórios. Caminho FrCaixa já configurado é preservado; caso ausente, descobre um único caminho de monitor.exe em execução, ou usa `C:\FrCaixaMonitor\monitor.exe`. Havendo múltiplos caminhos, interrompe sem escolher por tentativa. RustDesk usa exclusivamente `C:\Program Files\RustDesk\RustDesk.exe`.

Backup de binário/scripts/configuração, exclusão mútua entre atualizadores e rollback automático permanecem ativos. Na falha, restaura também a configuração anterior. Identidade e diário de comandos não são restaurados para versões antigas nem sobrescritos. O iniciador não faz downgrade nem recria cadastros excluídos no backend. Instalações novas usam o instalador web atualizado; `-MonitoringOnly` permanece disponível no instalador local para deixar as ações desabilitadas.

## Catálogo no heartbeat

```json
[
 {"id":"frcaixa","kind":"process","allowed_operations":["start","stop","restart","kill"],"allow_force":true},
 {"id":"rustdesk","kind":"process","allowed_operations":["start","stop","restart","kill"],"allow_force":true},
 {"id":"system_cleanup","kind":"process","allowed_operations":["start"],"allow_force":false}
]
```

Caminhos e `remote_control_enabled` são configuração local, nunca recebidos como autorização via comando. Outros alvos existentes ficam monitorados sem operações remotas nessa transformação.

## Comandos e confirmação

Aceita `id`, `target_id`, `operation`, `reason` no pull autenticado. Se `host_id` existir, deve corresponder à identidade local; se omitido, o destino é vinculado à resposta HTTPS autenticada daquele host. Não aceitar comandos por arquivo, URL arbitrária, shell ou outro canal.

Se `expires_at` vier, o prazo é conferido contra o horário HTTPS do servidor quando disponível. Se omitido no contrato simplificado, aplica janela local de 5 minutos desde o recebimento; o backend deve entregar somente comandos ainda válidos. A fila tem limite, deduplicação e um único worker. A decisão de frescor também usa tempo monotônico na fila.

Antes do efeito, grava intenção durável. Depois, grava resultado e tenta `agent-action-result` imediatamente, com `command_id`, `result` e `message` de até 500 caracteres. Rede indisponível repete somente a confirmação. Uma queda entre o efeito e sua confirmação persistida gera resultado incerto no reinício, sem repetir a operação. A fila não bloqueia o worker de métricas ou a thread principal de heartbeat/poll.

## FrCaixa

- Usa o executável absoluto autorizado localmente. Não presume que um processo é um serviço Windows.
- Residual `frcaixa.exe`, `monitor.exe`, `monitorthread.exe` só é encerrado se estiver no MESMO diretório autorizado. Executável principal também é considerado. Outros diretórios não são atingidos; instalações com componentes distribuídos precisam de configuração/validação separada.
- Confere caminho, criação e PID, mantendo handle aberto para reduzir risco de atingir PID reciclado.
- Stop/restart tenta encerramento normal e só força com autorização local. Kill não inicia novamente.
- Serviço Windows com binário exatamente correspondente usa SCM; descoberta ambígua ou caminho sem aspas com espaços é recusado. Sem serviço, inicia na sessão interativa ativa do usuário.
- Restart exige um PID novo do executável principal em até 8s após iniciar; start já ativo é idempotente. Processo ativo não prova saúde funcional do ERP.

## RustDesk

- Verifica o caminho fixo e acesso do usuário ANTES de encerrar processos.
- Sessão ativa obtida por WTS: prefere console ativo, senão uma única sessão ativa. Ausência/ambiguidade é erro, não inicia na sessão 0.
- Serviço LocalSystem usa token do usuário, ambiente e `CreateProcessAsUser`, no desktop `winsta0\default`, com janela minimizada/sem ativar e argumento local fixo `--tray` do RustDesk. O suporte ao argumento foi conferido no código oficial `rustdesk/rustdesk/src/core_main.rs`; a versão instalada ainda deve ser homologada. Aplicações que exijam elevação UAC específica podem falhar: não há bypass de UAC ou senha embutida.
- Se existir serviço cujo binário seja exatamente RustDesk.exe, controla-o via SCM para não matar o transporte e deixá-lo abandonado. Depois trata processos residuais do MESMO executável e reinicia GUI na sessão ativa.
- Aguarda 2s após encerramento no restart e confirma novo PID na sessão ativa em até 8s. Start/stop/kill também são aceitos, conforme o catálogo obrigatório; stop/kill não religam automaticamente o aplicativo.
- Reiniciar/parar RustDesk pode interromper a sessão remota de suporte; o agente continua a execução local e envia resultado ao painel.

## Limpeza Windows 10/11

- Recusa Windows Server para essa ação. Requer referência de horário HTTPS recente e relógio local com diferença menor que 5 minutos, para não apagar temporários recentes em lojas com hora incorreta.
- Limpa temporários do agente e Windows, além de `AppData\Local\Temp` do usuário ativo, quando disponível. Não percorre perfis de todos os usuários.
- Arquivos precisam ter criação E última escrita há mais de 24h. Arquivos bloqueados, somente leitura/sistema, hardlinks e reparse points são preservados.
- Mantém handle da raiz e verifica caminho físico do arquivo antes de marcar exclusão. Não segue junctions para fora do escopo. Varredura limitada a 20 mil entradas/100s; fila de diretórios limitada para controlar memória.
- Esvazia a lixeira do usuário ativo no volume C: por API Shell sob impersonação; não promete apagar lixeiras de outros usuários. Sem sessão ativa, essa etapa é reportada como parcial.
- Após verificar suporte TRIM no dispositivo do volume C:, o TRIM equivalente a `Optimize-Volume -ReTrim` usa somente `defrag.exe C: /L /U /V`, do diretório do Windows, sem shell ou parâmetros de rede. Nunca usa `/D` para desfragmentação. O Windows decide suporte do volume; código não zero ou timeout não é anunciado como sucesso.
- Retorna quantidade/bytes de temporários e aumento livre em C: (estimativa sujeita a outras gravações). Etapas incompletas retornam `error` com informação parcial, sem desfazer arquivos já removidos. Arquivos em uso/novos preservados são comportamento esperado, não erro.

## Backend Lovable

O protocolo continua schema_version=2 e não exige migration nova neste repositório. O backend publicado precisa:
- Autorizar admin, motivo, host e catálogo antes de enfileirar.
- Reentregar comandos dispatched válidos e aceitar confirmações idênticas sem auditoria duplicada.
- Aceitar resultados tardios de operações já executadas e mensagem de até 500 caracteres.
- Exibir resultado error/parcial, sem rotular automaticamente como concluído.
- Não usar heartbeat ausente ou leitura unknown como autorização para reinício automático.
- Manter a proibição de controle em hosts sem política/clock adequados, conforme configuração administrativa do projeto.

## Validação e promoção

Compilação C# 5/.NET Framework 4.7.2/x86 e testes portáveis do núcleo, fila, catálogo, contrato e banco local são executados neste ambiente. APIs WTS/SCM/Shell/NTFS/TRIM e as três operações reais não foram executadas em Windows aqui.

Testar primeiro em uma loja de homologação/controlada: sessão ativa, RustDesk instalado, aplicativo de teste autorizado no lugar do ERP, limpeza com arquivos descartáveis >24h/novos/bloqueados/links e volume TRIM suportado. Validar cancelamento, rede indisponível, reboot, rollback e RAM durante a ação (<50 MB preferencial, <100 MB obrigatória). Não apresentar compilação como prova de funcionamento no Windows.
