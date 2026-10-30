# Histórico de alterações

As datas seguem o histórico Git quando existe commit correspondente. Uma entrada neste arquivo não implica tag ou release publicada. As versões 1.0.0 e 1.2.2 têm observações específicas abaixo para não atribuir ao histórico versões que não foram publicadas separadamente.

## Não publicado

- Corrige a compatibilidade da CI com ShellCheck 0.9/0.10: passa o diretório de logs explicitamente e documenta os mocks chamados indiretamente, sem desativar a análise do código de produção.
- Restringe a exceção `safe.directory` ao checkout e a cada comando Git de validação; verifica que existe uma árvore de trabalho e confere também whitespace do commit. Não usa confiança global em todos os repositórios.
- Registra as versões de Bash/ShellCheck na CI para facilitar a comparação com a validação local.

## 1.3.4 — 2026-10-29

- Corrige a referência temporal do journal: usa `__REALTIME_TIMESTAMP` (recebimento) em vez do horário exibido por `short-unix`, que pode ser o de origem. A diferença podia excluir o último registro e produzir uma coleta vazia apesar de existir boot anterior.
- Mantém ID de boot fixo, janela temporal, microssegundos e limites FAST/FULL, sem dependências novas ou consulta causal sem janela.
- Distingue inconsistência de coleta de ausência de logs: consulta geral vazia após referência válida ou timestamp inválido retornam `3`. Uma janela sem eventos de kernel continua sendo válida.
- Acrescenta regressões sintéticas para atraso de recebimento e atualiza a explicação da janela no README.
- Corrige a classificação de desligamentos por terminal/menu: mensagens genéricas do logind não são mais apresentadas como ACPI, botão ou possível glitch elétrico.
- Reconhece `poweroff.target`, `reboot.target` e `halt.target` alcançados como sequência ordenada registrada, sem afirmar a conclusão física do desligamento. Eventos explícitos `Power key pressed` são mostrados separadamente; isolados, mantêm resultado inconclusivo.
- Inclui regressões para solicitação genérica, desligamento ordenado em FAST/FULL, tecla de energia e etapas intermediárias sem conclusão registrada.
- Correlaciona perdas e recuperações IPMI por sensor/condição: recuperação até a referência cancela a perda anterior. Sequência/solicitação de desligamento registrada não é substituída por hipótese elétrica.
- Restringe o SEL ao intervalo do boot analisado, usando o primeiro registro disponível como limite conservador; sem essa referência, mantém apenas histórico. Usa recebimento do último registro como referência IPMI, sem misturar horário de origem.
- Separa coleta geral de coleta confiável do sistema, filtrada por metadados de PID/UID/unidade/processo. Mensagens citadas por aplicativos ou tags semelhantes não confirmam desligamento.
- Limita bytes nas consultas do journal e nos metadados; descarta amostras do journal que excedam o teto e informa erro. Contagem de registros não inclui continuações de mensagens multilinha.
- Normaliza `SIGPIPE` apenas nos produtores das capturas limitadas, inclusive sob supervisores que ignoram esse sinal; verifica suporte a `env --default-signal` antes da coleta (GNU coreutils 8.31+).
- Expõe falhas/timeouts e ausência de amostras na coleta histórica; não usa saída parcial de consultas que falharam. Mantém o corte deliberado de amostras `.gz`, com aviso.
- Executa cenários de integração em processos Bash independentes, preservando `errexit`/`ERR`; amplia regressões dos casos revisados.
- Configura CI em Debian 12/13 e Ubuntu 24.04/26.04 com permissões mínimas e action fixada por commit; inclui o texto integral da GPLv3 e atualiza o README.

## 1.3.3 — 2026-09-23

- Destaca resultado e grau de certeza: vermelho para reinício possivelmente abrupto ou panic, amarelo para causa incerta e indício elétrico, ciano para ACPI e verde para sequência registrada.
- Coloca o aviso de reinício abrupto antes da explicação e a análise antes do histórico detalhado de boots, para leitura rápida.
- Mantém saída sem ANSI em pipes e respeita `NO_COLOR`.
- Adiciona testes para cores e ausência de sequências ANSI em saída redirecionada.

## 1.3.2 — 2026-09-23

- Restaura o aviso "Reinício possivelmente abrupto" quando o boot anterior termina sem sequência de shutdown, sem tratar hipótese como causa comprovada (`exit 2`).
- Destaca eventos de perda AC no SEL com relógio divergente como indício histórico; não desloca timestamps nem classifica automaticamente o reboot como falha elétrica.
- Acrescenta regressões para boot abrupto, ausência de journal, relógio divergente e evento elétrico correlacionado.

## 1.3.1 — 2026-09-22

- Aceita datas IPMI `MM/DD/YY`, além de `MM/DD/YYYY`, com e sem AM/PM.
- Distingue falha de interpretação e divergência de relógio, mostrando hora do host e diferença host/BMC em segundos.
- Compara relógios antes da consulta SEL e só avisa sobre fuso ausente quando o horário realmente não informa fuso.
- Mantém SEL com relógio divergente como histórico; não desloca eventos automaticamente para encaixá-los no reboot.
- Adiciona regressões para o formato SEL com ano curto, anos-limite, atraso/adiantamento e correlação temporal.

## 1.3.0 — 2026-09-21

Correções da implementação Bash. Migração para Python reservada para uma versão posterior.

### Corrigido

- Filtro de indícios históricos e do kernel restringido a eventos explícitos: ignora Power Button/udev, CUPS, groups e inicialização térmica; omite cabeçalhos sem ocorrências e avisos de touchpad/libinput contendo `kernel bug:`.

- Logs históricos deixam de determinar a causa do último reboot.
- Extração de timestamp sem hostname; microssegundos preservados no limite superior da consulta.
- Referência temporal obtida do último registro em `short-unix`, com ID de boot fixo e confirmação do boot atual.
- Nenhuma consulta causal sem janela quando a referência temporal estiver inválida.
- Mensagens normais de UPS/PSU, watchdog habilitado e inicialização de atualizações deixam de gerar causas automáticas.
- SEL distingue `Asserted`, `Deasserted` e restauração de redundância; normaliza datas AM/PM com offset.
- Correlação IPMI exige relógio BMC compatível e exclui eventos posteriores ao início do boot atual.
- OOM, Oops, lockups, segfaults e erros de disco isolados passam a ser indícios.
- Ausência de sequência de shutdown passa a retornar inconclusivo (`2`).
- Extração de evidências evita encerramento prematuro causado por `grep | head` com `pipefail`.
- Salvamento exige `mktemp`, mantém permissão privada e verifica a conclusão do `tee`.

### Melhorado

- Timeouts IPMI de 30/60 segundos, com encerramento forçado e descarte de SEL parcial em falha.
- Amostras históricas limitadas por quantidade de arquivos, bytes e tempo de leitura.
- Opções explícitas `--fast` e `-h`; erros de execução diferenciados dos resultados inconclusivos.
- Testes de regressão com dados sintéticos, sem acesso ao hardware.
- README reestruturado com requisitos, limitações, códigos de saída e referências oficiais.

## 1.2.4 — 2026-02-04

Referência: `4491b7f`.

- Filtro temporal movido para `journalctl --since/--until`.
- Padrões de OOM ampliados; segfault rebaixado para indício.
- Introduzidos códigos de saída e tratamento para ausência de `journalctl`.
- As limitações de classificação e retorno dessa versão são corrigidas em 1.3.0.

## 1.2.3 — 2026-02-04

Referência: `887862b`.

- Referência de fim do boot obtida de `journalctl --list-boots`.
- Coleta SEL com `ipmitool sel list last 50` e fallback.
- Incluída a janela temporal desenvolvida sob a identificação intermediária 1.2.2.
- Criado o changelog.

## 1.2.2 — 2026-02-04 (etapa intermediária)

Alterações incorporadas ao commit `887862b`, já identificado como 1.2.3. Não há commit independente dessa versão no histórico consultado.

- Introduzida janela de 30 minutos próxima do desligamento/último log.
- Correlação IPMI passa a usar o último registro quando não há shutdown.
- Linha do tempo passa a mostrar o último registro do boot anterior.

## 1.2.1 — 2026-02-03

Referência: `ea21f1d`.

- Introduzidos `mktemp` no relatório e timeouts no IPMI.
- Corrigidos os campos de data/hora do SEL para campos 2 e 3.
- Aplicado `LC_ALL=C` na conversão de datas.
- Acrescentado `machine_restart` à expressão de reboot da época.

## 1.2.0 — 2026-02-03

Referências: `1d2b48e`, `f5918a9` e `6a5fcca`.

- Removida dependência de `last`; adicionadas fontes journal/kernel e linha do tempo.
- Reorganizados FAST/FULL; IPMI opcional no FULL.
- Adicionadas heurísticas de ACPI, energia e falhas do kernel.
- Introduzidos número de versão e `--version`.
- Incluído hostname no relatório e no nome do arquivo, ainda sob 1.2.0.

## 1.0.0 — 2025-12-04 (identificação retrospectiva)

Referências: `15660e9` e `fe2d3aa`.

- Primeira implementação do script e documentação inicial.
- O nome 1.0.0 foi atribuído posteriormente no changelog; não indica uma tag original dessa data.
