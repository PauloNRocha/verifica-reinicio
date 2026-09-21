# verifica-reinicio

Ferramenta Bash para investigar o último reinício ou desligamento de um servidor Linux. Reúne registros do journal, identifica evidências e, no modo FULL, consulta logs históricos e o SEL do IPMI.

**Versão:** 1.3.0 — 21 de setembro de 2026

O foco é Debian 12/13, Ubuntu e hosts Proxmox VE com systemd. A ferramenta não comprova automaticamente a causa de todo reinício: ausência de logs, retenção, relógios divergentes e falhas de hardware podem impedir uma conclusão.

## Como interpretar o resultado

| Resultado | Significado |
| --- | --- |
| Evidência forte: kernel panic | O kernel registrou um panic na janela analisada. |
| Causa provável: energia | O SEL contém uma falha elétrica `Asserted` próxima da referência temporal, com relógio BMC compatível. Não prova que todas as fontes perderam energia. |
| Mecanismo registrado: ACPI/Power key | O logind registrou o evento ou solicitação de desligamento. Não identifica ação humana, UPS ou glitch elétrico. |
| Sequência de reinício/desligamento registrada | Há mensagem final explícita do kernel/systemd; a origem da solicitação pode permanecer desconhecida. |
| Motivo não conclusivo | As evidências disponíveis não permitem classificar o evento com segurança. |

OOM, segfault, Oops, lockup, erros de disco e mensagens térmicas isoladas são apresentados como **indícios**. A ocorrência desses eventos não demonstra, por si só, que provocaram o reboot. A ativação normal do NMI watchdog e a inicialização de `unattended-upgrades` não são consideradas causas.

## Requisitos

- Bash 4.4 ou posterior.
- GNU coreutils, `grep`, `awk` e `sed`.
- `journalctl` para analisar o journal; sem ele, o FULL ainda apresenta amostras históricas.
- `gzip` para consultar arquivos `.gz` no FULL; opcional.
- `ipmitool` para consultar o BMC local no FULL; opcional.
- Execução como root para acesso consistente às fontes. `--help` e `--version` dispensam root.

Não requer Python, `pip`, `last`, serviço residente ou acesso à rede. A consulta IPMI usa a interface local `-I open`. Não há busca com `find /`.

## Instalação

Em um diretório destinado às ferramentas administrativas:

```bash
git clone https://github.com/PauloNRocha/verifica-reinicio.git
cd verifica-reinicio
```

Revise o script e execute com Bash. Não é necessário alterar a permissão de execução:

```bash
bash ./verifica-reinicio.sh --version
bash ./verifica-reinicio.sh --help
sudo bash ./verifica-reinicio.sh
```

## Modos de execução

### FAST: análise rápida

```bash
sudo bash ./verifica-reinicio.sh --fast
```

É o modo padrão. Consulta o journal geral e do kernel, o histórico de boots e informações leves do sistema. Não varre os logs legados em `/var/log`, não consulta IPMI e não carrega módulos.

### FULL: fontes adicionais

```bash
sudo bash ./verifica-reinicio.sh --full
```

Além do journal, apresenta amostras dos arquivos `syslog*`, `kern.log*`, `messages*` e `dmesg*`, incluindo `.gz` quando `gzip` está disponível. Esses arquivos podem conter registros de outros boots e **nunca determinam a causa automaticamente**. O filtro seleciona eventos explícitos de falha ou desligamento, omitindo mensagens rotineiras de dispositivos, CUPS e monitoramento térmico, além de avisos de touchpad/libinput que apenas contêm o texto `kernel bug:`. Arquivos sem ocorrências selecionadas não geram cabeçalhos vazios. São exibidas até dez ocorrências finais por amostra; isso não garante ordem cronológica entre arquivos rotacionados.

O FULL também lista entradas de `/var/crash`, consulta `systemd-analyze` e tenta acessar o IPMI. Arquivos em `/var/crash` não são necessariamente dumps do kernel ou do último incidente.

**Efeito no sistema:** quando `ipmitool` existe, o FULL tenta carregar `ipmi_si` e `ipmi_devintf`. As consultas SEL são de leitura; o script não limpa eventos, ajusta relógios ou modifica a configuração do journal.

### Salvar o relatório

```bash
sudo bash ./verifica-reinicio.sh --full --save
```

O arquivo inclui hostname, data, hora e sufixo aleatório:

```text
/tmp/analise-reinicio-HOST-AAAA-MM-DD_HH-MM-SS-XXXXXX.log
```

`HOST` e `XXXXXX` representam, respectivamente, o hostname sanitizado e o sufixo gerado por `mktemp`. O arquivo é criado com permissão `600`. Se a criação segura falhar, a execução termina com erro. O script aguarda o gravador antes de confirmar a gravação.

O relatório pode conter IPs, usuários, nomes de máquinas e mensagens de aplicações. Revise o conteúdo antes de compartilhar. `/tmp` não é armazenamento permanente; preserve o relatório no local usado pela sua equipe para incidentes.

## Janela temporal e limites

A análise usa os últimos **30 minutos anteriores ao último registro disponível** do boot anterior, mantendo os microssegundos. Esse horário não é necessariamente o momento da queda de energia.

O histórico identifica o boot, mas seus horários formatados não são usados para o cálculo. O script confirma que o boot `0` corresponde ao sistema atual, fixa o ID do boot anterior e lê o último timestamp em `short-unix`. As consultas seguintes usam `--since` e `--until` nesse mesmo ID. Sem referência válida, não há análise automática do journal sem janela.

| Coleta | Limite padrão |
| --- | --- |
| Journal FAST | 1.500 registros por consulta |
| Journal FULL | 8.000 registros por consulta |
| Cada comando journalctl | 30 segundos, mais até 3 segundos para encerramento forçado |
| Logs históricos FULL | Até 24 arquivos; amostra de até 2 MiB por arquivo |
| Arquivo histórico texto | Últimos 2 MiB |
| Arquivo `.gz` | Primeiros 2 MiB descompactados; até 5 segundos, mais 2 para encerramento |
| Relógio IPMI | 30 segundos, mais até 5 para encerramento |
| SEL IPMI | Até 50 eventos; 60 segundos, mais até 5 para encerramento |

Os limites estão definidos no início do script. Atingir um limite pode deixar evidências de fora; FULL significa mais contexto, não auditoria completa de todos os arquivos. A janela temporal não garante que um evento encontrado causou o reboot.

## Correlação IPMI

A referência é a mensagem de desligamento, quando disponível, ou o último log do boot anterior. O script busca eventos em até 15 minutos antes/depois dessa referência, excluindo eventos posteriores ao início do boot atual.

Para usar o SEL na classificação:

- O horário do BMC deve ser interpretável e diferir em no máximo cinco minutos do relógio atual do host.
- O início do boot atual deve estar disponível e próximo da referência, em até 30 minutos. Intervalos maiores exigem investigação manual.
- A descrição deve indicar perda elétrica explícita, como `Power Supply AC lost`, com estado `Asserted`.

`Deasserted` indica que a condição deixou de estar ativa e não é tratado como nova perda de energia. `Fully Redundant` também não indica falha. Falhas de uma fonte redundante não comprovam interrupção total do host.

Datas SEL com AM/PM e offset são normalizadas antes da comparação. Quando o BMC não informa fuso, assume-se o fuso local; confira essa configuração. A comparação com o relógio atual não garante que o BMC estava sincronizado na data do incidente.

Se o IPMI estiver ausente, falhar ou expirar, a análise continua com as outras fontes. Saída SEL parcial de uma consulta que falhou é descartada. Sem correlação confiável, os eventos são apenas históricos.

## Códigos de saída

| Código | Significado |
| --- | --- |
| `0` | Evidência forte, causa elétrica provável correlacionada ou mecanismo/sequência explícita registrada. Não significa certeza absoluta sobre a causa raiz. |
| `1` | Argumento inválido. |
| `2` | Motivo inconclusivo, inclusive possível interrupção abrupta sem evidência causal. |
| `3` | Erro de execução: falta de root/dependência básica, falha de coleta do journal ou gravação, por exemplo. |

Ajuda e versão retornam `0`. Ausência de IPMI opcional não provoca erro de execução. Para verificar o retorno, execute imediatamente após o script:

```bash
echo "$?"
```

## Quando não há logs do boot anterior

A ausência pode resultar de armazenamento volátil, retenção, limpeza ou indisponibilidade do journal. A existência de `/var/log/journal` sozinha não determina a configuração efetiva.

Consulte o histórico:

```bash
sudo journalctl --list-boots --no-pager
```

Verifique `Storage=` e os arquivos de configuração adicionais do journald antes de modificar a persistência. A documentação oficial descreve `persistent`, `volatile`, `auto` e o papel de `journalctl --flush`. O script não muda essas configurações automaticamente.

## Desenvolvimento e validação

```bash
bash -n verifica-reinicio.sh
shellcheck -x -P SCRIPTDIR verifica-reinicio.sh tests/regressao.sh
bash tests/regressao.sh
```

Os testes usam dados sintéticos e comandos simulados. Não consultam o BMC, carregam módulos ou precisam de root. Cobrem o incidente com último log às 12:21 e `AC lost` às 12:28, falsos positivos, horários, códigos de saída e gravação segura.

Esses testes não substituem validação em um host Debian/Proxmox com BMC real. A implementação permanece em Bash nesta versão; a migração para Python ficará em uma versão dedicada.

## Histórico e referências

As alterações estão no [CHANGELOG.md](CHANGELOG.md) e no histórico Git. Algumas versões antigas foram documentadas retrospectivamente, conforme indicado no changelog.

- [journalctl — Debian 13](https://manpages.debian.org/trixie/systemd/journalctl.1.en.html)
- [journald.conf — Debian 13](https://manpages.debian.org/trixie/systemd/journald.conf.5.en.html)
- [ipmitool — Debian 13](https://manpages.debian.org/trixie/ipmitool/ipmitool.1.en.html)
- [Kernel: panic_on_oom](https://kernel.org/doc/html/latest/admin-guide/sysctl/vm.html#panic-on-oom)

## Licença e créditos

Licenciado sob **GPL-3.0-or-later**. Consulte [LICENSE](LICENSE) e o [texto da GNU GPLv3](https://www.gnu.org/licenses/gpl-3.0.html).

Autor: **Paulo Rocha ([PauloNRocha](https://github.com/PauloNRocha))**.

Criado com apoio do ChatGPT (OpenAI) na concepção e refinamento.
