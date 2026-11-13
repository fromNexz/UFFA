# Scripts remotos — 2.2.0

O agente anuncia `powershell` e `cmd` como processos com `allowed_operations: ["start"]` e `allow_force: false` no heartbeat. Sao capacidades do executavel, adicionadas automaticamente mesmo ao atualizar catalogos antigos. Alvos repetidos sao normalizados; o limite aceita os 64 alvos locais anteriores mais estas duas capacidades.

Os scripts chegam exclusivamente na fila HTTPS autenticada `agent-pull-config`, vinculados ao host. O campo `reason` e preservado pelo agente. A autorizacao de administradores, catalogo do host e registro de auditoria continuam no backend. Nao ha porta de entrada nova nem servico permanente adicional.

## Envio pelo painel

Exemplo de comando:

```json
{
  "target_id": "powershell",
  "operation": "start",
  "reason": "{\"script\":\"Get-Service RustDesk | Select-Object Name,Status\",\"timeout\":60,\"working_dir\":\"C:\\Windows\\Temp\"}"
}
```

O envelope recebido tambem inclui `id`, `host_id` e `expires_at`, conforme a fila atual. `reason` deve ser string; nao enviar o objeto JSON diretamente nesse campo. Texto puro como `Get-Service RustDesk` ou `ver` tambem funciona, com timeout 60 segundos e diretorio `%TEMP%` do servico. Objetos JSON com aparencia de metadados mas malformados retornam erro; expressoes PowerShell como `[Console]::WriteLine('ok')` e blocos de script continuam aceitas como texto puro.

`timeout` aceita inteiro positivo, em segundos, e nao e reduzido silenciosamente. O diretorio opcional deve existir e ser absoluto; variaveis de ambiente sao expandidas. `reason` e limitado a 16.000 caracteres e o script a 12.000; comandos que ultrapassem a linha de comando do Windows retornam erro antes de iniciar.

## Execucao e retorno

PowerShell usa `-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "& { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8; <script> }"`, com escape de argumento Windows para preservar aspas, barras e quebras de linha. CMD usa `/d /c "<script>"`. Interpretadores sao resolvidos em caminhos fixos do Windows; em Windows x64 o agente x86 usa Sysnative para executar os interpretadores nativos x64.

A execucao usa a conta do servico (normalmente LocalSystem) e a sessao do servico. Ela nao abre automaticamente uma interface na sessao do usuario; para iniciar a interface do RustDesk na sessao ativa, use a acao especifica RustDesk. Scripts de consulta/controle de servicos podem ser executados sem sessao interativa.

Stdout e stderr sao drenados em blocos, decodificados como UTF-8 e combinados na ordem de leitura dos dois pipes; nao ha garantia de ordem temporal exata entre streams. O buffer guarda no maximo 1.800 caracteres mais `[... truncado]`, sem acumular toda a saida em memoria. Programas externos que gravem outra pagina de codigo precisam ser configurados para emitir UTF-8; o decoder nao transforma bytes OEM em UTF-8 automaticamente.

O processo nasce suspenso, e associado a um Job Object antes de poder criar filhos e so entao e liberado. Somente stdin/stdout/stderr sao herdados. No timeout ou parada do agente, TerminateJobObject encerra a arvore inteira; isso substitui Kill(entireProcessTree), indisponivel no .NET Framework 4.7.2. Se nao for possivel criar/associar o Job Object, o script nao e liberado. Em conclusao normal, descendentes iniciados intencionalmente podem continuar; a captura termina com o interpretador, sem aguardar pipes de processos em background indefinidamente.

Resultados seguem `agent-action-result`: `[Exit 0]\n<saida>` com `ok`; outro exit code com `error`; timeout com `[Timeout Ns] O comando excedeu o tempo limite e foi cancelado pelo agente.`. Erros de parse, caminho ou criacao tambem sao persistidos como resultado terminal. O diario preserva mensagens de script ate 2.000 caracteres; acoes antigas conservam limite de 500. Falha de rede mantem o resultado para retransmissao, sem repetir o script. Um ID ja concluido nao e reexecutado. Expiracao/cancelamento antes de executar continua respeitada; apos interrupcao abrupta, o diario registra resultado incerto e nao repete automaticamente.

## Atualizacao e integracao Lovable

Execute `maintenance/COMANDO-ATUALIZAR-2.2.0.txt` em PowerShell como administrador em uma loja piloto; cadastro, UUID/token e catalogo anterior sao preservados. O heartbeat seguinte anuncia os novos alvos. Scripts arbitrarios podem consumir recursos proprios; a meta de RAM do agente nao e um limite de memoria imposto aos scripts.

O codigo de referencia Lovable foi atualizado: fila preserva `reason`, validacao/constraint aceitam ate 16.000 caracteres somente para scripts, formulario permite esse tamanho e resultados mantem quebras de linha. Em projetos que usam estas tabelas `im_*`, aplicar `lovable/supabase/migrations/202611130001_remote_scripts.sql` e publicar a Edge Function/painel atualizados. Em projetos com outro esquema, adaptar o mesmo contrato. Essa publicacao e separada da publicacao GitHub; nao foi aplicada automaticamente ao site do usuario. `agent-action-result` deve aceitar mensagens de pelo menos 2.000 caracteres e `agent-pull-config` deve incluir `reason` nos comandos.

## Validacao

81 testes portaveis do agente, 33 testes de backend/banco e typecheck, compilacao C# 5 / .NET Framework 4.7.2 / x86. As suites existentes de instalacao/atualizacao tambem sao verificadas antes da release. Testes de politica e diario executam no Linux; nao simulam uma validacao real dos handles/Job Object do Windows.

A suite `tests/ScriptExecution.Windows.Tests.ps1 -AgentExe <caminho-do-InfraMonitor.Agent.exe>` cobre processos reais, UTF-8 PowerShell, aspas CMD, streams volumosos simultaneos, exit code, working_dir invalido e timeout de filho. Ela precisa ser executada no piloto Windows. Nao foi possivel executar essa suite neste ambiente Linux, nem medir RAM/CPU dos interpretadores no Windows.
