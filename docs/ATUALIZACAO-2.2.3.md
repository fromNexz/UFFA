# Atualizacao dos agentes para 2.2.3

Execute o bloco de `maintenance/COMANDO-ATUALIZAR-2.2.3.txt` em Windows PowerShell 5.1 como administrador. O bloco baixa o atualizador RAW, verifica seu SHA256 e executa a atualizacao. A pasta padrao e `C:\infra-monitor-unificado`; informe `-Root 'D:\outra-pasta'` na chamada ao arquivo baixado caso a instalacao use outro caminho.

Esta versao combina a limpeza oficial OTM ([contrato](SYSTEM-CLEANUP-RAW.md)) e o long-polling dedicado. O atualizador exige uma instalacao existente com identidade e servico reconhecidos. Nao cadastra novo host nem gera token. Versao igual ou superior e preservada. O script verifica o backend autenticado com `wait=25`, timeout de 35s, antes de parar o agente; fila vazia deve levar pelo menos 20 segundos. Se o servidor responder imediatamente, a atualizacao e cancelada para evitar chamadas continuas. A fila com comandos e deixada para o agente atual; se o teste nao obtiver resposta vazia em tres tentativas, aguarde a conclusao dos comandos e repita.

O pacote e o atualizador possuem hashes fixos. O pacote e baixado de um commit imutavel, validado pelo SHA256 e pelo manifesto dos arquivos. O atualizador reutiliza `scripts/Update.ps1`: cria backup, verifica a parada dos processos da instalacao, substitui agente/helper/scripts, reinicia o servico e aguarda heartbeat autenticado. Se houver falha apos a parada, tenta restaurar o backup e confirmar a versao anterior. UUID/token, diario de comandos e configuracoes sao preservados; a migracao de catalogo existente continua restrita a versoes anteriores a 2.1.0.

O script confirma funcionamento do agente pelo heartbeat. A limpeza OTM somente roda quando o painel enviar `system_cleanup/start`; atualizar nao executa limpeza. Operacoes de limpeza/comandos que estejam em andamento podem ser interrompidas pela parada do agente, portanto programe a atualizacao fora de sua execucao.

As tags e pacotes antigos nao foram alterados. Compilacao C# 5/.NET Framework 4.7.2/x86 e testes portaveis foram executados antes da publicacao; SCM, substituicao de binario carregado e heartbeat reais ainda exigem validacao em uma loja piloto Windows.
