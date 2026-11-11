# Reinicio RustDesk — 2.1.3

O resultado antigo `Acao restart falhou (InvalidOperationException)` nao permite determinar qual chamada falhou. O agente capturava a excecao sem conservar etapa ou codigo nativo interno. Nao e possivel confirmar a causa na loja somente com essa mensagem.

Esta versao aguarda servicos em StartPending/StopPending/ContinuePending/PausePending estabilizarem antes de enviar outra ordem; aguarda ate 25 segundos por fase e respeita cancelamento/prazo do comando. Servico que nao aceita parada e preservado, sem tentar matar seus processos como substituto. Uma disputa em que outro componente conclui o estado solicitado e aceita somente se o SCM confirmar o estado final.

Um processo pode encerrar apos a coleta WMI e antes de consultar StartTime ou fechar sua janela. InvalidOperationException nessa janela e aceita apenas se o mesmo objeto Process confirmar HasExited. Validacoes de caminho, criacao, permissao de forca e identidade do PID permanecem obrigatorias.

O resultado agora identifica a etapa (inventario, sessao, acesso, parada de servico, encerramento de processo, inicio de servico, inicio interativo ou validacao do PID), tipo da excecao e codigo Win32 interno quando disponivel, ou HRESULT. Mensagens brutas de excecao e credenciais nao sao enviadas. Exemplo: `Acao restart falhou na etapa parar servico Windows (InvalidOperationException; Win32=5)` indica acesso negado nessa etapa, em vez de pressupor problema no painel.

Atualize usando maintenance/COMANDO-ATUALIZAR-2.1.3.txt em PowerShell como administrador, preservando UUID/token/catalogo. Crie uma nova solicitacao no painel: o diario nao reexecuta o ID de comando anterior. Confirme novo PID na sessao ativa; se falhar, envie o novo resultado com etapa/codigo. Nao e necessario recadastrar nem reinstalar RustDesk por tentativa.

67 testes portaveis e compilacao .NET Framework passaram. Transicoes SCM foram simuladas; nao houve reinicio real de RustDesk neste ambiente Linux. Validar primeiro na loja afetada. Nao foram adicionados servicos, processos residentes ou permissao de controle ao catalogo.
