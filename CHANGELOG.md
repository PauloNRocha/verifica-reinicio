# Histórico de alterações

As datas seguem o histórico Git quando existe commit correspondente. Uma entrada neste arquivo não implica tag ou release publicada. As versões 1.0.0 e 1.2.2 têm observações específicas abaixo para não atribuir ao histórico versões que não foram publicadas separadamente.

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
