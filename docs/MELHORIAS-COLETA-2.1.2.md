# Coleta e desempenho — 2.1.2

Atualizacao sobre 2.1.1, preservando UUID, token, catalogo e permissoes existentes. O atualizador so migra o catalogo quando a origem e anterior a 2.1.0, conforme procedimento existente.

## Precisao

- IPs: uma falha ICMP/TCP recebe uma segunda tentativa; sucesso na primeira nao repete. TCP continua exigindo todas as portas configuradas. ICMP bloqueado continua significando que o teste ICMP falhou: configure TCP para destinos que nao respondem a ping.
- TCP usa a familia de enderecos do destino, inclusive IPv6. Portas repetidas sao testadas uma vez; todas sao validadas antes de iniciar as conexoes.
- Cache identificado por IP normalizado e portas ordenadas. Alterar portas provoca leitura nova; dados anteriores nao sao reutilizados como leitura atual depois de reiniciar.
- Agendamento de IPs usa Stopwatch, independente de ajustes do relogio. Leituras reaproveitadas conservam seu checked_at original.
- Configuracao recebida e validada antes de substituir intervalos/IPs em uso. Limites continuam em 128 alvos e 32 portas por alvo.
- Servicos com caminho contendo espacos ou variaveis de ambiente sao comparados ao executavel autorizado com limite de argumento, sem aceitar prefixos de outros executaveis. Caminhos com espacos sem aspas sao aceitos para observacao, mas permanecem bloqueados no controle generico por serem ambiguos para o Windows.
- Processo com nome encontrado mas caminho inacessivel e informado como desconhecido, em vez de parado, quando nao ha instancia verificavel pelo caminho.
- Processo encontrado sem data de criacao legivel continua presente; inicio/uptime ficam nulos. Data futura nao produz uptime negativo. A observacao por nome de monitor.exe continua independente de sessao, e nao amplia permissoes de controle.
- Uptime do Windows usa GetTickCount64 em vez de diferenca entre horarios; IPs locais sao ordenados e sem duplicatas, loopback, enderecos indefinidos ou IPv6 link-local/multicast.

## Custo e limites

Nao ha novos timers, servicos ou processos permanentes. Mantidas frequencias padrao, um coletor de cada vez e limites de memoria existentes. Eliminada a serializacao seguida de desserializacao de cada leitura de IP. Servico parado dispensa consulta de seus processos; consultas WMI recebem timeout de 10 segundos (limite solicitado ao provedor, nao cancelamento forcado de todo o coletor).

A segunda tentativa aumenta o tempo de coleta de destinos inacessiveis, limitada a duas tentativas por teste. O polling de comandos continua em outra thread. Nao ha descoberta por varredura da rede nem envio a servicos externos de IP publico.

## Validacao

60 testes portaveis, incluindo regressao de cache, ordem/alteracao de portas, IPv6, confirmacao de falha, cadencia monotona, caminho de servico e uptime desconhecido. Compilacao de agente e helper em C# 5 / .NET Framework 4.7.2 / x86. Suites existentes de contrato/backend, instalacao e atualizacao executadas antes da publicacao.

O ambiente de compilacao e Linux. WMI, rede real da loja, SCM e consumo real de RAM/CPU ainda precisam de piloto Windows; nao ha medicao que permita prometer <50 MB. Execute scripts/Measure-Agent.ps1 para medir o agente e helper, incluindo ao menos uma coleta completa. Meta <50 MB, teto solicitado <100 MB; os limiares de reinicio existentes sao protecao suave, nao limite de memoria do Windows. Compare o painel com Get-Process, Get-Service e Test-NetConnection; valide um IP acessivel, um inacessivel e mudanca de portas.
