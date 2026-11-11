# Correção da Lixeira — 2.1.1

Relato observado na 2.1.0: 770 temporários removidos, TRIM concluído, porém resultado parcial "lixeira nao concluida". A API era chamada dentro do serviço sob impersonação e o HRESULT era descartado no resumo. Isso não comprova corrupção nem necessidade de apagar a estrutura de todas as lixeiras.

## Mudança

- A Lixeira passa a ser tratada por `bin/InfraMonitor.UserTask.exe`, helper pequeno iniciado por `CreateProcessAsUser` com o token do usuário ativo. Não instala outro serviço nem inicia junto do Windows.
- O helper confere o SID real do próprio processo, só aceita a ação fixa e só opera em C:. Não aceita caminhos, scripts ou outras unidades.
- Estrutura SHQUERYRBINFO de 20 bytes/pack 1 conferida no header shellapi.h do SDK Microsoft (repositório microsoft/win32metadata).
- API Shell executada no processo real do usuário, com consulta antes/depois. Lixeira já vazia ou diretório do próprio SID ainda inexistente retorna sucesso. Consulta que falhou não é confundida com Lixeira vazia.
- Falhas são devolvidas como HRESULT hexadecimal, por exemplo `0x80070005`, em vez de apenas "lixeira nao concluida".
- O serviço aguarda até 60s e encerra somente seu helper em cancelamento/timeout. Temporários e TRIM continuam independentes e o resultado pode ser parcial.

Não há exclusão recursiva de `C:\$Recycle.Bin\*`, de SIDs de outros usuários, de outras unidades ou da própria pasta do sistema. O escopo continua usuário ativo/C:. Limpeza global requer outra configuração e autorização; não é fallback desta correção.

## Distribuição e permissões

Atualizar pelo comando RAW de `maintenance/COMANDO-ATUALIZAR-2.1.1.txt`, como administrador. O pacote contém agente e helper com mesma versão e manifesto de integridade. A cópia/rollback inclui o helper. Não copiar apenas o executável principal.

Somente o helper público tem ReadAndExecute para usuários autenticados. Raiz e bin recebem somente Traverse, sem herança e sem permissão para listar diretórios. Configuração, identidade, logs e estado continuam protegidos por SYSTEM/Administradores. Usuários não podem alterar o helper; ele roda sem privilégios adicionais, no contexto do usuário cuja Lixeira será esvaziada.

Ao atualizar de 2.1.0, preserva o catálogo e as permissões já existentes. Ao atualizar versões anteriores a 2.1.0, mantém a migração de manutenção remota já autorizada na entrega anterior. Tokens/UUID não são recriados.

## Validação

54 testes portáveis do núcleo/regras passaram, incluindo consulta vazia versus consulta com erro, preservação do HRESULT e rejeição de outro SID/caminho/ação. Compilação de agente e helper em C# 5/.NET Framework 4.7.2/x86. APIs Shell, ACLs e início real na sessão Windows exigem piloto: este ambiente Linux não comprova o esvaziamento de uma Lixeira real.

A ferramenta Measure-Agent.ps1 agora conta também o helper transitório. RAM <50 MB preferencial/<100 MB obrigatória precisa ser medida no Windows durante a limpeza. Reinício FrCaixa/RustDesk não é disparado por essa atualização.

Após atualizar uma loja piloto, solicitar uma nova limpeza pelo painel. Se a Lixeira continuar falhando, enviar apenas o HRESULT/mensagem nova. Não repetir a exclusão global recomendada por outro sistema e não remover proteções para esconder uma falha.
