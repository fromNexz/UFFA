# system_cleanup com o script oficial OTM

`target_id=system_cleanup` e `operation=start` executam o script fixo em `https://raw.githubusercontent.com/fromNexz/UFFA/refs/heads/main/otm/otimizar.ps1`. A URL nao vem do comando remoto. A autorizacao do catalogo local e a deduplicacao por command_id continuam obrigatorias.

A acao utiliza o worker de manutencao existente, fora do loop que agenda heartbeat, coletas e busca de comandos. O PowerShell nativo e escolhido por caminho absoluto (Sysnative no agente x86 em Windows x64). Argumentos: `-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command`, com UTF-8, TLS 1.2, `irm ... | iex` e tratamento de falha no download. O download tem timeout de 60s; todo o processo tem limite de 960s (16 minutos). O script OTM tambem tem seu proprio limite preventivo de 900s.

O executor usa CreateProcess sem shell, CREATE_NO_WINDOW e pipes UTF-8 (equivalentes a UseShellExecute=false / CreateNoWindow=true). O processo nasce suspenso e entra em um Job Object antes de iniciar. Timeout ou parada do agente terminam forcadamente o processo e seus descendentes, usando TerminateJobObject, inclusive ferramentas de limpeza filhas. A acao nao usa o antigo limite de cinco minutos da limpeza nativa.

O stdout e examinado em streaming com memoria limitada. O resumo final permanece disponivel mesmo depois de logs extensos; stderr e mantido separadamente para diagnostico e nao e interpretado como resumo. A ultima linha `[OTM_RESULT]` precisa conter STATUS, LIBERADO_MB, LIVRE_ATUAL_GB e TEMPO_SEG numericos. MB pode ser negativo: o script mede a variacao livre do disco, que pode diminuir se outros processos gravarem dados. Decimais com virgula sao normalizados para ponto.

- OK/PARCIAL: result=ok, por exemplo `Limpeza concluída (PARCIAL). 1234 MB liberados (Livre atual: 50.25 GB) em 42s.`
- ERRO/TIMEOUT e demais estados nao bem-sucedidos do script: result=error, por exemplo `Limpeza falhou com status TIMEOUT após 900s.`
- Timeout forcado sem resumo de erro: result=error, mensagem solicitada `Tempo limite de 15 minutos excedido durante a limpeza do sistema.` O watchdog efetivo e de 960s.
- Cancelamento, codigo de saida diferente de zero, falha de rede/processo, ou resumo ausente/invalido: result=error. Diagnostico com prefixo `Falha ao executar limpeza:`, limitado a 500 caracteres. Um processo cancelado ou com saida nao zero nunca e confirmado como sucesso, mesmo se imprimiu OK antes de falhar.

O diario grava o resultado e o worker envia POST `agent-action-result` pela mesma instancia Api autenticada: headers X-Host-Id/X-Host-Token, JSON `{command_id,result,message}`. A rota e relativa a `api_base_url` existente: com base `https://servidor/api/public`, o destino e `https://servidor/api/public/agent-action-result`. Nao se concatena `/api/public` duas vezes nem se altera a base das lojas. Uma falha de entrega tenta reenviar o resultado sem executar a limpeza novamente.

O heartbeat preserva `allowed_operations` para o backend existente e inclui `supported_operations`, anunciando `system_cleanup`, `kind=process`, `supported_operations=["start"]` a partir do catalogo local. Operacoes diferentes de start continuam rejeitadas.

Validacao: testes portaveis cobrem estados, unidades usadas pelo badge, saida extensa, fragmentacao de linhas, valores negativos/decimais, timeout, cancelamento, erro de rede/saida, limite de mensagem, diario e catalogo. A suite `tests/ScriptExecution.Windows.Tests.ps1` inclui fixtures inofensivas para o executor real (logs extensos e timeout com captura UTF-8); nao baixa nem executa a limpeza oficial. Essa suite exige Windows. A compilacao para .NET Framework 4.7.2/x86 pode ser verificada separadamente.

Esta alteracao e de codigo-fonte: os pacotes ja publicados nao sao modificados. Para aplicar nas lojas, compile e distribua uma nova versao do agente com este codigo.
