# verifica-reinicio

Ferramenta Bash para investigar o último reinício ou desligamento de um servidor Linux. Reúne registros do journal, identifica evidências e, no modo FULL, consulta logs históricos e o SEL do IPMI.

**Versão:** 1.3.4 — 29 de outubro de 2026

O foco é Debian 12/13, Ubuntu e hosts Proxmox VE com systemd. A ferramenta não comprova automaticamente a causa de todo reinício: ausência de logs, retenção, relógios divergentes e falhas de hardware podem impedir uma conclusão.

## Como interpretar o resultado

| Resultado | Significado |
| --- | --- |
| Evidência forte: kernel panic | O kernel registrou um panic na janela analisada. |
| Causa provável: energia | O SEL contém uma perda elétrica próxima da referência, sem recuperação registrada antes dela, dentro dos limites do boot e com relógio BMC compatível. Não há sequência/solicitação de desligamento registrada que tenha prioridade. Não prova que todas as fontes perderam energia. |
| Solicitação de desligamento registrada pelo sistema | O logind registrou `Powering off` ou `System is powering down`. Não distingue terminal, menu ou automação, nem comprova a conclusão do desligamento. |
| Sequência de reinício/desligamento ordenado registrada | Há mensagem final explícita do kernel/systemd ou um target de desligamento/reinício alcançado. Não identifica quem solicitou nem comprova a conclusão física do desligamento. |
| Evento da tecla de energia registrado (Power key) | Há um evento explícito `Power key pressed`. É mostrado separadamente; sozinho não comprova desligamento, acionamento humano ou falha elétrica. |
| Reinício possivelmente abrupto; motivo não conclusivo | Há registros do boot anterior, mas não há sequência normal de shutdown nem evidência causal suficiente. O resultado continua sendo `2`. |
| Motivo não conclusivo | Não há dados utilizáveis ou os disponíveis não permitem classificar o evento com segurança. |

OOM, segfault, Oops, lockup, erros de disco e mensagens térmicas isoladas são apresentados como **indícios**. A ocorrência desses eventos não demonstra, por si só, que provocaram o reboot. A ativação normal do NMI watchdog e a inicialização de `unattended-upgrades` não são consideradas causas.

Um desligamento por `poweroff` no terminal ou pelo menu pode produzir a mesma sequência no journal. A mensagem genérica do logind não é evidência de botão físico ou problema elétrico. O script informa o que foi registrado, sem presumir a origem da solicitação.

A classificação de desligamento usa uma coleta separada, filtrada na origem pelos metadados do journal: PID 1 com UID 0, ou a unidade `systemd-logind.service` com processo `systemd-logind` e UID 0. Mensagens do journal geral que apenas citam `systemd[1]`, ou usam esse identificador como tag, não bastam. Os padrões também exigem o emissor e a mensagem na posição esperada. Kernel panic e reinício do kernel são analisados na coleta de transporte kernel (`-k`).

## Requisitos

- Bash 4.4 ou posterior.
- GNU coreutils 8.31 ou posterior (incluindo `env --default-signal`), `grep`, `awk` e `sed`. Disponíveis nas versões Debian/Ubuntu alvo.
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

É o modo padrão. Consulta o journal geral, do kernel e dos emissores de sistema usados na classificação, além do histórico de boots e informações leves do sistema. Não varre os logs legados em `/var/log`, não consulta IPMI e não carrega módulos.

### FULL: fontes adicionais

```bash
sudo bash ./verifica-reinicio.sh --full
```

Além do journal, apresenta amostras dos arquivos `syslog*`, `kern.log*`, `messages*` e `dmesg*`, incluindo `.gz` quando `gzip` está disponível. Esses arquivos podem conter registros de outros boots e **nunca determinam a causa automaticamente**. O filtro seleciona eventos explícitos de falha ou desligamento, omitindo mensagens rotineiras de dispositivos, CUPS e monitoramento térmico, além de avisos de touchpad/libinput que apenas contêm o texto `kernel bug:`. Arquivos sem ocorrências selecionadas não geram cabeçalhos vazios. São exibidas até dez ocorrências finais por amostra; isso não garante ordem cronológica entre arquivos rotacionados.

Erros de leitura, arquivos comprimidos inválidos e timeouts geram aviso de coleta incompleta; sua saída parcial é descartada. Se nenhum arquivo puder ser consultado, isso é informado sem sugerir que houve uma busca bem-sucedida sem eventos. O corte deliberado por bytes de um `.gz` continua permitido, com aviso, descartando o fragmento da última linha. Falhas dessas fontes opcionais não alteram, sozinhas, o código de saída.

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

A análise aparece antes do histórico detalhado de boots, para leitura rápida. A saída usa cores quando conectada a um terminal, respeita `NO_COLOR` e permanece sem ANSI em pipes. Com `--save` no terminal, o relatório também pode conter códigos ANSI. O relatório pode conter IPs, usuários, nomes de máquinas e mensagens de aplicações. Revise o conteúdo antes de compartilhar. `/tmp` não é armazenamento permanente; preserve o relatório no local usado pela sua equipe para incidentes.

## Janela temporal e limites

A análise usa os últimos **30 minutos anteriores ao último registro disponível** do boot anterior, mantendo os microssegundos. Esse horário não é necessariamente o momento da queda de energia.

O histórico identifica o boot, mas seus horários formatados não são usados para o cálculo. O script confirma que o boot `0` corresponde ao sistema atual, fixa o ID do boot anterior e lê o metadado `__REALTIME_TIMESTAMP` em formato `export`. Esse é o horário de recebimento usado pelos filtros do journal. Os formatos `short-unix` e `short-iso-precise` podem exibir o horário de origem (`_SOURCE_REALTIME_TIMESTAMP`), ligeiramente anterior; usá-lo como limite pode excluir até o último registro disponível.

As consultas seguintes usam `--since` e `--until` nesse mesmo ID, preservando os microssegundos. Sem referência válida, não há análise automática do journal sem janela. Se a consulta geral retornar vazia após a leitura de uma referência válida, o script informa inconsistência de coleta e retorna `3`; não amplia a janela nem conclui que os logs não existem. Já a consulta do kernel pode retornar vazia normalmente, se não houver eventos de kernel no intervalo.

| Coleta | Limite padrão |
| --- | --- |
| Journal FAST | 1.500 registros por consulta |
| Journal FULL | 8.000 registros por consulta |
| Journal geral, kernel ou sistema | Até 8 MiB por consulta; exceder descarta a amostra e retorna `3` |
| Histórico de boots / referência final | Até 1 MiB / 64 KiB |
| Referência inicial do boot (FULL) | Primeiros 4 KiB de metadados; sem interpretar o histórico formatado |
| Cada comando journalctl | 30 segundos, mais até 3 segundos para encerramento forçado |
| Logs históricos FULL | Até 24 arquivos; amostra de até 2 MiB por arquivo |
| Arquivo histórico texto | Últimos 2 MiB |
| Arquivo `.gz` | Primeiros 2 MiB descompactados; até 5 segundos, mais 2 para encerramento |
| Relógio IPMI | 30 segundos, mais até 5 para encerramento |
| SEL IPMI | Até 50 eventos; 60 segundos, mais até 5 para encerramento |

Os limites estão definidos no início do script. Atingir um limite pode deixar evidências de fora; FULL significa mais contexto, não auditoria completa de todos os arquivos. A janela temporal não garante que um evento encontrado causou o reboot.

O aviso de limite de registros conta o início das entradas, não as linhas de continuação de mensagens multilinha. O limite de bytes protege também contra poucas mensagens muito grandes. Dados cortados do journal não sustentam diagnóstico.

O produtor de cada captura limitada recebe o comportamento padrão de `SIGPIPE`, mesmo se o processo que iniciou o script ignorava esse sinal. Isso permite distinguir corte planejado de erros reais de leitura, sem ignorar erros do `gzip` ou do journal.

## Correlação IPMI

A referência é o horário de **recebimento do último registro do boot anterior** (`__REALTIME_TIMESTAMP`). O horário de origem exibido na linha do tempo não substitui essa referência. O script busca eventos em até 15 minutos antes/depois dela, excluindo eventos anteriores ao primeiro registro disponível daquele boot e eventos a partir do início do boot atual.

O FULL lê o primeiro registro por uma consulta de metadados limitada. Esse registro pode ser posterior ao início real do boot, por retenção ou atraso de gravação; o limite é conservador. Sem ele, não há classificação automática pelo SEL. Uma perda iniciada antes desse limite pode continuar relevante para investigação manual, mas não é atribuída automaticamente ao último reinício.

Para usar o SEL na classificação:

- O horário do BMC deve ser interpretável e diferir em no máximo cinco minutos do relógio atual do host.
- O início do boot atual deve estar disponível e próximo da referência, em até 30 minutos. Intervalos maiores exigem investigação manual.
- A descrição deve indicar perda elétrica explícita, como `Power Supply AC lost`, com estado `Asserted`, sem `Deasserted` posterior do mesmo sensor/condição até a referência.
- Mensagens confiáveis de desligamento têm prioridade sobre uma hipótese elétrica. Falha na coleta do journal também impede promover o SEL a causa provável.

Os eventos são ordenados pelo horário interpretado e pareados por sensor e condição. `Deasserted` até a referência cancela a perda anterior correspondente; a recuperação de outra fonte não a cancela. Recuperação depois do último registro ainda pode ser compatível com uma interrupção, por isso não exclui automaticamente a hipótese. `Fully Redundant` não indica falha. O estado é o observado na amostra, não uma consulta da saúde atual. Falhas de uma fonte redundante não comprovam interrupção total do host.

Datas SEL com ano de dois ou quatro dígitos, AM/PM e offset são normalizadas antes da comparação. Anos `00..68` representam `2000..2068`; `69..99`, `1969..1999`, conforme a convenção do GNU date. O relatório diferencia formato inválido de relógio divergente, mostra a hora do host na consulta e a diferença em segundos. Relógios históricos não são deslocados automaticamente. Quando o BMC não informa fuso, assume-se o fuso local; confira essa configuração. A comparação com o relógio atual não garante que o BMC estava sincronizado na data do incidente.

Se o IPMI estiver ausente, falhar ou expirar, a análise continua com as outras fontes. Saída SEL parcial de uma consulta que falhou é descartada. Sem correlação confiável, os eventos são apenas históricos. Se houver uma perda de entrada AC registrada e não houver shutdown no journal, o FULL destaca isso como indício, sem deslocar horários ou atribuir causa automaticamente.

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
for arquivo in tests/*.sh; do bash -n "$arquivo"; done
shellcheck -x -P SCRIPTDIR verifica-reinicio.sh tests/*.sh
bash tests/regressao.sh
```

Os testes usam dados sintéticos e comandos simulados. Não consultam o BMC, carregam módulos ou precisam de root. Cobrem perda/recuperação por sensor, limites entre boots, mensagens citadas por aplicativos, limites de bytes, logs comprimidos inválidos, timestamps e códigos de saída. Preservam as regressões de recebimento/origem, último registro em FAST/FULL, sequência ordenada e tecla de energia.

`tests/integracao.sh` é o executor dos cenários de integração, chamado pela suíte em processos Bash independentes. Assim, falhas inesperadas exercitam `set -e` e o trap `ERR`, sem desativá-los por envolver `main` em uma condição.

O workflow `.github/workflows/validacao.yml` configura sintaxe, ShellCheck e regressões em containers Debian 12/13 e Ubuntu 24.04/26.04. Usa permissão somente de leitura do repositório e não persiste credenciais. A instalação de pacotes acontece apenas nos containers de CI, não no host diagnosticado. A matriz só representa validação executada após o workflow terminar com sucesso no GitHub.

Esses testes não substituem validação em um host Debian/Proxmox com BMC real. A implementação permanece em Bash nesta versão; a migração para Python ficará em uma versão dedicada.

## Histórico e referências

As alterações estão no [CHANGELOG.md](CHANGELOG.md) e no histórico Git. Algumas versões antigas foram documentadas retrospectivamente, conforme indicado no changelog.

- [journalctl — Debian 13](https://manpages.debian.org/trixie/systemd/journalctl.1.en.html)
- [Metadados e timestamps do journal — systemd](https://www.freedesktop.org/software/systemd/man/257/systemd.journal-fields.html)
- [Operações de desligamento via logind — systemd](https://www.freedesktop.org/software/systemd/man/259/org.freedesktop.login1.html)
- [journald.conf — Debian 13](https://manpages.debian.org/trixie/systemd/journald.conf.5.en.html)
- [ipmitool — Debian 13](https://manpages.debian.org/trixie/ipmitool/ipmitool.1.en.html)
- [Kernel: panic_on_oom](https://kernel.org/doc/html/latest/admin-guide/sysctl/vm.html#panic-on-oom)

## Licença e créditos

Licenciado sob **GPL-3.0-or-later**. Consulte [LICENSE](LICENSE) e o [texto da GNU GPLv3](https://www.gnu.org/licenses/gpl-3.0.html).

Autor: **Paulo Rocha ([PauloNRocha](https://github.com/PauloNRocha))**.

Criado com apoio do ChatGPT (OpenAI) na concepção e refinamento.
