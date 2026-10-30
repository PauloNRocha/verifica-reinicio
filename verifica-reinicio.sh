#!/usr/bin/env bash
#
# Ferramenta para analisar o motivo do último reinício em sistemas Linux
# (Debian/Ubuntu/AlmaLinux/RHEL/Rocky, inclusive ambientes com cPanel).
#
# Autor: Paulo Rocha (PauloNRocha)
# Copyright (C) 2025 Paulo Rocha
# GitHub: https://github.com/PauloNRocha
#
# Criado com apoio do ChatGPT (OpenAI) na concepção e refinamento.
#
# Licença: GPL-3.0-or-later
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Você tem o direito de usar, copiar, modificar e redistribuir este script,
# desde que preserve este cabeçalho com os créditos e mantenha a mesma licença.
# O texto completo da licença está disponível em:
#   https://www.gnu.org/licenses/gpl-3.0.txt
#

set -euo pipefail

# =========================[ CORES ]=======================================

init_colors() {
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        C_RESET=$'\e[0m';  C_BOLD=$'\e[1m'
        C_RED=$'\e[31m';   C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[34m';  C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
    else
        C_RESET=""; C_BOLD=""
        C_RED="";   C_GREEN=""; C_YELLOW=""
        C_BLUE="";  C_MAGENTA=""; C_CYAN=""
    fi
}

# ========================[ GLOBALS ]======================================

MODE="FAST"
SAVE=0
SAVE_FILE=""

SCRIPT_VERSION="1.3.4"
SCRIPT_DATE="2026-10-29"

FAST_LIMIT=1500
FULL_LIMIT=8000

BOOT_LIST=""
PREVIOUS_BOOT_ID=""
PREVIOUS_BOOT_START_EPOCH=""
BOOT_END_EPOCH=""
CURRENT_BOOT_EPOCH=""
JOURNAL_TIMEOUT=30
JOURNAL_MAX_BYTES=8388608
JOURNAL_PREFIX='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+'
IPMI_TIMEOUT=30
IPMI_LIST_TIMEOUT=60
IPMI_TIME_WINDOW=900
IPMI_CLOCK_TOLERANCE=300
IPMI_CLOCK_OK=0
IPMI_CLOCK_DELTA=""
IPMI_HOST_TIME=""
AUX_MAX_FILES=24
AUX_MAX_BYTES=2097152
AUX_TIMEOUT=5
TEE_PID=""

BOOT_LIST_LIMIT_FAST=5
BOOT_LIST_LIMIT_FULL=15
EVID_LIMIT_FAST=5
EVID_LIMIT_FULL=12
CAUSE_WINDOW_SEC=1800
EXIT_CODE=0

SHUTDOWN_TS=""
BOOT_END_TS=""
REF_TS=""
IPMI_AVAILABLE=0
IPMI_SEL_TIME=""
IPMI_SEL_LIST=""
IPMI_SEL_NEAR=""
HOSTNAME_RAW="desconhecido"
HOSTNAME_SAFE="desconhecido"

# =======================[ AJUDA ]=========================================

show_help() {
    local status="${1:-0}"
cat << EOF
${C_BOLD}Uso:${C_RESET} sudo $0 [opções]

Opções disponíveis:

  --fast        Análise do journal (padrão), sem varrer /var/log ou consultar IPMI
  --full        Inclui logs históricos, .gz e IPMI opcional
  --save        Salva relatório em /tmp/analise-reinicio-HOST-AAAA-MM-DD_HH-MM-SS-XXXXXX.log
  --version     Mostra a versão do script
  -h, --help    Mostra esta ajuda

Saída: 0 = evidência forte, causa provável ou mecanismo registrado;
       1 = argumento inválido;
       2 = inconclusivo; 3 = erro de execução ou gravação.

Modo padrão (sem flags):
  * FAST → Análise rápida usando journalctl + padrões essenciais.

Exemplos:
  sudo $0
  sudo $0 --full
  sudo $0 --save
  sudo $0 --full --save
EOF
exit "$status"
}

show_version() {
    echo "verifica-reinicio.sh versão $SCRIPT_VERSION ($SCRIPT_DATE)"
    exit 0
}

# =======================[ PARSE ARGS ]====================================

parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --fast)
                MODE="FAST"
                ;;
            --full)
                MODE="FULL"
                ;;
            --save)
                SAVE=1
                ;;
            --version)
                show_version
                ;;
            -h|--help)
                init_colors
                show_help
                ;;
            *)
                init_colors
                echo -e "${C_RED}ERRO:${C_RESET} opção desconhecida: $arg" >&2
                show_help 1
                ;;
        esac
    done
}

# =======================[ ROOT CHECK ]====================================

requer_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_RED}ERRO:${C_RESET} este script precisa ser executado como root."
        exit 3
    fi
}

# =======================[ INFO DO SISTEMA ]===============================

mostra_info_sistema() {
    echo -e "${C_BOLD}${C_CYAN}Sistema detectado:${C_RESET}"
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        echo "  ${PRETTY_NAME:-${ID:-desconhecido}}"
    else
        echo "  (não foi possível detectar via /etc/os-release)"
    fi
    echo "  Hostname: ${HOSTNAME_RAW}"
    echo

    echo -e "${C_BOLD}${C_CYAN}Boot atual:${C_RESET}"
    if uptime -s >/dev/null 2>&1; then
        uptime -s
    else
        uptime 2>/dev/null || true
    fi
    echo
}

mostra_boot_overview() {
    local limit="$BOOT_LIST_LIMIT_FAST"
    [[ "$MODE" == "FULL" ]] && limit="$BOOT_LIST_LIMIT_FULL"

    echo -e "${C_BOLD}${C_CYAN}==== HISTÓRICO DE BOOTS (journalctl --list-boots) ====${C_RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        printf '%s\n' "$BOOT_LIST" | tail -n "$limit"
    else
        echo "Comando 'journalctl' não encontrado."
    fi
    echo

    echo -e "${C_BOLD}${C_CYAN}Boot registrado (who -b):${C_RESET}"
    if command -v who >/dev/null 2>&1; then
        who -b || true
    else
        echo "Comando 'who' não encontrado."
    fi
    echo

    if [[ "$MODE" == "FULL" ]] && command -v systemd-analyze >/dev/null 2>&1; then
        echo -e "${C_BOLD}${C_CYAN}systemd-analyze:${C_RESET}"
        timeout -k 3s 10s systemd-analyze 2>/dev/null || true
        echo
    fi
}

# =======================[ CRASH DUMPS ]===================================

verifica_crash_dumps() {
    if [[ -d /var/crash ]] && [[ -n "$(ls -A /var/crash 2>/dev/null)" ]]; then
        echo -e "${C_BOLD}${C_MAGENTA}Arquivos em /var/crash (sem correlação automática):${C_RESET}"
        # Listagem para apresentação, sem interpretar nomes de arquivos.
        # shellcheck disable=SC2012
        ls -lh /var/crash 2>/dev/null | sed -n '1,10p' || true
        echo
    fi
}

# =======================[ JOURNAL ]=======================================

# Retorno 4 indica corte deliberado por bytes; erros do produtor não são ocultados.
captura_limitada() {
    local max="$1" data status=0 LC_ALL=C
    shift
    data="$(
        rc=0
        # Alguns supervisores ignoram SIGPIPE. Restaurá-lo só no produtor evita
        # confundir o corte planejado com um erro real de leitura/descompressão.
        env --default-signal=PIPE "$@" | head -c "$((max + 1))" || rc=$?
        printf '\001'
        exit "$rc"
    )" || status=$?
    data="${data%$'\001'}"
    if (( status != 0 && status != 141 )); then
        return "$status"
    fi
    if (( ${#data} > max )); then
        printf '%s' "${data:0:max}"
        return 4
    fi
    (( status == 0 )) || return "$status"
    printf '%s' "$data"
}

prepara_journal() {
    BOOT_LIST=""
    PREVIOUS_BOOT_ID=""
    PREVIOUS_BOOT_START_EPOCH=""
    BOOT_END_EPOCH=""
    BOOT_END_TS=""
    if ! command -v journalctl >/dev/null 2>&1; then
        echo "Aviso: journalctl não encontrado. O modo FULL pode mostrar indícios em /var/log." >&2
        return 0
    fi
    local current_id last_entry last_usec first_entry first_usec status=0
    if ! BOOT_LIST="$(LC_ALL=C captura_limitada 1048576 timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl --list-boots --no-pager 2>/dev/null)"; then
        echo "Aviso: não foi possível listar os boots; análise do journal indisponível." >&2
        EXIT_CODE=3
        return 0
    fi
    # Só aceitamos -1 quando o último boot listado é o boot deste sistema.
    current_id="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)"
    current_id="${current_id//-/}"
    if [[ -z "$current_id" || "$(awk '$1 == "0" {print $2}' <<< "$BOOT_LIST")" != "$current_id" ]]; then
        echo "Aviso: histórico não ancorado no boot atual; não será usado como causa." >&2
        return 0
    fi
    PREVIOUS_BOOT_ID="$(awk '$1 == "-1" {print $2}' <<< "$BOOT_LIST")"
    if [[ ! "$PREVIOUS_BOOT_ID" =~ ^[0-9a-f]{32}$ ]]; then
        PREVIOUS_BOOT_ID=""
        echo "Aviso: sem boot anterior acessível. Retenção, configuração ou armazenamento podem explicar a ausência." >&2
        return 0
    fi
    if ! last_entry="$(LC_ALL=C captura_limitada 65536 timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl -b "$PREVIOUS_BOOT_ID" -n 1 \
        -o export --output-fields=__REALTIME_TIMESTAMP --quiet --no-pager 2>/dev/null)"; then
        echo "Erro: falha ou timeout ao obter a referência do boot anterior." >&2
        EXIT_CODE=3
        return 0
    fi
    # Os filtros usam o horário de recebimento; short-unix pode exibir o de origem.
    last_usec="$(awk -F= '$1 == "__REALTIME_TIMESTAMP" {print $2; exit}' <<< "$last_entry")"
    if [[ ! "$last_usec" =~ ^[1-9][0-9]{6,17}$ ]]; then
        echo "Aviso: timestamp inválido; não será feita análise sem janela temporal." >&2
        EXIT_CODE=3
        return 0
    fi
    printf -v BOOT_END_EPOCH '%d.%06d' "$((last_usec / 1000000))" "$((last_usec % 1000000))"
    if ! BOOT_END_TS="$(LC_ALL=C date -d "@$BOOT_END_EPOCH" '+%Y-%m-%dT%H:%M:%S.%6N%:z' 2>/dev/null)"; then
        BOOT_END_EPOCH=""
        echo "Erro: não foi possível converter o timestamp do boot anterior." >&2
        EXIT_CODE=3
        return 0
    fi
    if [[ "$MODE" == "FULL" ]]; then
        # --no-tail funciona no Debian 12; lemos só o começo do fluxo de metadados.
        first_entry="$(LC_ALL=C captura_limitada 4096 timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl \
            -b "$PREVIOUS_BOOT_ID" --no-tail -o export --output-fields=__REALTIME_TIMESTAMP --quiet --no-pager 2>/dev/null)" || status=$?
        first_usec="$(awk -F= '$1 == "__REALTIME_TIMESTAMP" {print $2; exit}' <<< "$first_entry")"
        if (( status == 0 || status == 4 )) && [[ "$first_usec" =~ ^[1-9][0-9]{6,17}$ ]] && (( first_usec <= last_usec )); then
            PREVIOUS_BOOT_START_EPOCH=$((first_usec / 1000000))
        else
            echo "Aviso: início dos registros do boot anterior indisponível; SEL apenas como histórico." >&2
        fi
    fi
}

coleta_journal_boot_anterior() {
    local kind="${1:-geral}" limite="$FAST_LIMIT" since_epoch data status=0
    local extra=()
    [[ "$MODE" == "FULL" ]] && limite="$FULL_LIMIT"
    [[ "$kind" == "kernel" ]] && extra=(-k)
    # Não usamos SYSLOG_IDENTIFIER/PID fornecidos pelo aplicativo como autoridade.
    [[ "$kind" == "sistema" ]] && extra=(_PID=1 _UID=0 + _SYSTEMD_UNIT=systemd-logind.service _COMM=systemd-logind _UID=0)
    [[ -n "$BOOT_END_EPOCH" && -n "$PREVIOUS_BOOT_ID" ]] || return 0
    since_epoch=$(( ${BOOT_END_EPOCH%%.*} - CAUSE_WINDOW_SEC ))
    (( since_epoch < 0 )) && since_epoch=0
    echo "Coletando journal ($kind), janela de ${CAUSE_WINDOW_SEC}s, até $BOOT_END_TS..." >&2
    data="$(LC_ALL=C captura_limitada "$JOURNAL_MAX_BYTES" timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl -b "$PREVIOUS_BOOT_ID" "${extra[@]}" \
        --since "@$since_epoch" --until "@$BOOT_END_EPOCH" -n "$limite" \
        --quiet --no-pager -o short-iso-precise 2>/dev/null)" || status=$?
    if (( status == 4 )); then
        echo "Erro: limite de $JOURNAL_MAX_BYTES bytes excedido no journal ($kind); amostra descartada para não analisar registro cortado." >&2
        return 3
    elif (( status != 0 )); then
        echo "Erro: falha ou timeout na coleta do journal ($kind)." >&2
        return 3
    fi
    if [[ "$kind" == "geral" && -z "$data" ]]; then
        echo "Erro: boot anterior identificado, mas a consulta temporal do journal retornou vazia; a coleta está inconsistente ou os registros foram removidos durante a análise." >&2
        return 3
    fi
    # No formato short, continuações são indentadas; linhas não equivalem a registros.
    if (( $(awk '/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ {n++} END {print n+0}' <<< "$data") >= limite )); then
        echo "Aviso: limite de $limite registros atingido; a janela pode estar incompleta." >&2
    fi
    printf '%s\n' "$data"
}

coleta_journal_kernel_boot_anterior() {
    coleta_journal_boot_anterior kernel
}

coleta_journal_sistema_boot_anterior() {
    coleta_journal_boot_anterior sistema
}

# =======================[ LOGS AUXILIARES (/var/log) ]====================

# Procura eventos explícitos, não nomes de dispositivos/serviços (Power Button,
# CUPS, grupos, governors térmicos). Usado também nos indícios do kernel.
filtra_indicios() {
    local data="$1" limit="${2:-10}" regex
    regex='\<kernel panic\>|\<Oops:|kernel:.*\<BUG:|\<(hard|soft) lockup\>|\<hung_task\>|blocked for more than [0-9]+ seconds|\<oom-killer\>|\<out of memory\>|\<Killed process [0-9]+|\<hardware error\>|\<Machine Check Exception\>|\<I/O error\>|EXT[2-4]-fs error|XFS.*(corrupt|error)|\<segfault\>|\<general protection fault\>'
    regex+='|critical temperature reached|temperature above threshold|thermal.*(critical temperature|shutdown)|Processor.*too hot'
    regex+='|\<power (failure|loss|outage)\>|\<AC lost\>|\<brownout\>|\<mains( power)?.*(lost|fail)|\<UPS\>.*(on battery|low battery|power fail)|power supply.*(failure|input lost)'
    regex+='|systemd-logind(\[[0-9]+\])?: (Power key pressed|Powering off|System is powering down)|systemd-shutdown\[[0-9]+\]: (Rebooting|Powering off)|kernel:.*reboot: (Restarting system|System reboot)'
    # Consome o pipe inteiro para evitar SIGPIPE; conserva as últimas ocorrências.
    grep -iE "$regex" <<< "$data" | tail -n "$limit" || true
}

coleta_logs_aux() {
    echo "Coletando amostras históricas de /var/log (não determinam a causa)..." >&2
    local f data matches count=0 found=0 failed=0 read_count=0 status
    local log_dir="${1:-/var/log}"
    for f in "$log_dir"/syslog* "$log_dir"/kern.log* "$log_dir"/messages* "$log_dir"/dmesg*;
    do
        [[ -f "$f" && -r "$f" && ! -L "$f" ]] || continue
        if (( count >= AUX_MAX_FILES )); then
            echo "Aviso: limite de $AUX_MAX_FILES arquivos históricos atingido." >&2
            break
        fi
        count=$((count + 1))
        status=0
        if [[ "$f" == *.gz ]]; then
            if ! command -v gzip >/dev/null 2>&1; then
                echo "Aviso: gzip ausente; arquivo histórico não consultado: $f" >&2
                failed=$((failed + 1))
                continue
            fi
            data="$(captura_limitada "$AUX_MAX_BYTES" timeout -k 2s "${AUX_TIMEOUT}s" gzip -cd -- "$f" 2>/dev/null)" || status=$?
            if (( status == 4 )); then
                # O limite pode cair no meio de uma linha; não exibir fragmentos.
                if [[ "$data" == *$'\n'* ]]; then data="${data%$'\n'*}"; else data=""; fi
                echo "Aviso: amostra descompactada limitada a $AUX_MAX_BYTES bytes: $f" >&2
                status=0
            fi
        else
            data="$(timeout -k 2s "${AUX_TIMEOUT}s" tail -c "$AUX_MAX_BYTES" -- "$f" 2>/dev/null)" || status=$?
        fi
        if (( status != 0 )); then
            echo "Aviso: falha/timeout na leitura histórica (código $status); amostra descartada: $f" >&2
            failed=$((failed + 1))
            continue
        fi
        read_count=$((read_count + 1))
        matches="$(filtra_indicios "$data")"
        if [[ -n "$matches" ]]; then
            printf '%s\n' "------ $f (amostra parcial; eventos sem correlação temporal) ------"
            printf '%s\n' "$matches"
            found=1
        fi
    done
    if (( failed > 0 )); then
        echo "Coleta histórica incompleta: $failed arquivo(s) não consultado(s) com sucesso." >&2
    fi
    if (( read_count == 0 )); then
        echo "Nenhuma amostra histórica pôde ser consultada." >&2
    elif [[ "$found" -eq 0 ]]; then
        echo "Nenhum evento relevante encontrado nas amostras históricas disponíveis." >&2
    fi
}

# =======================[ ANÁLISE ]=======================================

analisa_reinicio() {
    local journal="$1" kernel="$2" aux="$3" ipmi="$4" sistema="${5:-}"
    local limite="$EVID_LIMIT_FAST" panic acpi power ipmi_power reboot shutdown request clues
    [[ "$MODE" == "FULL" ]] && limite="$EVID_LIMIT_FULL"
    local rx_power='(power (failure|loss|outage)|AC lost|brownout|mains.*(lost|fail)|UPS.*on battery|power supply.*(failure|input lost))'
    # Exigimos emissor do kernel para panic; OOM/Oops/lockup isolados são indícios.
    panic="$(grep -iE -m "$limite" "${JOURNAL_PREFIX}kernel: Kernel panic" <<< "$kernel" || true)"
    acpi="$(grep -iE -m "$limite" "${JOURNAL_PREFIX}"'systemd-logind(\[[0-9]+\])?: Power key pressed([[:space:].]|$)' <<< "$sistema" || true)"
    request="$(grep -iE -m "$limite" "${JOURNAL_PREFIX}"'systemd-logind(\[[0-9]+\])?: (Powering off|System is powering down)' <<< "$sistema" || true)"
    power="$(grep -iE "$rx_power" <<< "$journal" | grep -viE 'restored|recovered|Deasserted|no power (loss|failure)|test|simulat' | sed -n "1,${limite}p" || true)"
    ipmi_power="$(seleciona_falhas_ipmi "$ipmi" "$REF_TS" | sed -n "1,${limite}p")"
    reboot="$(
        grep -iE -m "$limite" "${JOURNAL_PREFIX}"'(systemd-shutdown\[1\]: (Rebooting|Powering off)|systemd\[1\]: Reached target (poweroff|reboot|halt)\.target([[:space:].]|$))' <<< "$sistema" || true
        grep -iE -m "$limite" "${JOURNAL_PREFIX}kernel: reboot: (Restarting system|System reboot)" <<< "$kernel" || true
    )"
    shutdown="$(extrai_shutdown_ts "$sistema")"
    clues="$(filtra_indicios "$kernel" "$limite")"

    echo -e "${C_BOLD}${C_GREEN}=========== ANÁLISE DO MOTIVO DO REINÍCIO ==========${C_RESET}"
    local result=2
    if [[ -n "$panic" ]]; then
        echo -e "${C_BOLD}${C_RED}Evidência forte: Kernel panic / travamento.${C_RESET}"
        printf '%s\n' "$panic"
        result=0
    elif [[ -n "$reboot" ]]; then
        echo -e "${C_BOLD}${C_GREEN}Sequência de reinício/desligamento ordenado registrada.${C_RESET}"
        echo "Origem da solicitação não determinada; o registro não comprova a conclusão física do desligamento."
        printf '%s\n' "$reboot"
        result=0
    elif [[ -n "$request" ]]; then
        echo -e "${C_BOLD}${C_CYAN}Solicitação de desligamento registrada pelo sistema.${C_RESET}"
        echo "O registro não distingue terminal, menu ou automação nem comprova a conclusão do desligamento."
        printf '%s\n' "$request"
        result=0
    elif [[ -n "$ipmi_power" && -z "$shutdown" && "$EXIT_CODE" -ne 3 ]]; then
        echo -e "${C_BOLD}${C_YELLOW}Causa provável: Perda/instabilidade de energia (rede elétrica/UPS/PSU).${C_RESET}"
        echo "Perda próxima ao fim do boot, sem recuperação registrada antes da referência; não comprova perda de todas as fontes."
        printf '%s\n' "$ipmi_power"
        result=0
    else
        if [[ -n "$shutdown" ]]; then
            echo -e "${C_BOLD}${C_YELLOW}Motivo não conclusivo:${C_RESET} início de desligamento sem evidência suficiente de conclusão ou causa."
        elif [[ -n "$journal" ]]; then
            echo -e "${C_BOLD}${C_RED}Reinício possivelmente abrupto:${C_RESET} não há sequência normal de shutdown no boot anterior."
            echo -e "${C_BOLD}${C_YELLOW}Causa não determinada.${C_RESET} Travamento, reset físico, perda de energia ou logs incompletos são possíveis."
        elif [[ "$EXIT_CODE" -eq 3 ]]; then
            echo -e "${C_BOLD}${C_YELLOW}Análise indisponível:${C_RESET} falha ou inconsistência na coleta do journal do boot anterior."
        else
            echo -e "${C_BOLD}${C_YELLOW}Motivo não conclusivo:${C_RESET} sem registros utilizáveis do boot anterior."
        fi
        if [[ "$MODE" == "FULL" && "$IPMI_CLOCK_OK" -eq 0 && -n "$IPMI_SEL_LIST" ]]; then
            local ipmi_historico
            ipmi_historico="$(awk -F'|' 'tolower($5) ~ /ac lost/ && tolower($NF) ~ /^[[:space:]]*asserted[[:space:]]*$/ {print; exit}' <<< "$IPMI_SEL_LIST")"
            if [[ -n "$ipmi_historico" ]]; then
                echo -e "${C_BOLD}${C_YELLOW}Indício elétrico:${C_RESET} o SEL registra perda de entrada AC; relógio BMC não validado impede vincular o evento a este reboot."
            fi
        fi
    fi
    if [[ -n "$ipmi" && ( -z "$ipmi_power" || -n "$panic$reboot$request$shutdown" || "$EXIT_CODE" -eq 3 ) ]]; then
        echo "------ Indícios IPMI na janela (exigem confirmação) ------"
        echo "Perdas recuperadas antes da referência não são causa provável; estados se referem à amostra, não à saúde atual."
        printf '%s\n' "$ipmi" | sed -n "1,${limite}p"
    fi
    if [[ -n "$power" ]]; then
        echo "------ Indícios elétricos no journal (exigem confirmação) ------"
        printf '%s\n' "$power"
    fi
    if [[ -n "$acpi" ]]; then
        echo -e "${C_CYAN}------ Evento da tecla de energia registrado (Power key) ------${C_RESET}"
        echo "O evento não comprova acionamento humano nem falha elétrica; isoladamente não confirma desligamento."
        printf '%s\n' "$acpi"
    fi
    if [[ -n "$clues" ]]; then
        echo "------ Indícios do kernel; ocorrência não comprova causa do reboot ------"
        printf '%s\n' "$clues"
    fi
    if [[ -n "$aux" ]]; then
        echo "------ Indícios históricos; sem correlação com o último reboot ------"
        printf '%s\n' "$aux"
    fi
    echo "===================================================="
    echo
    # Uma coleta que falhou não se torna bem-sucedida por haver outra evidência.
    [[ "$EXIT_CODE" -eq 3 ]] || EXIT_CODE="$result"
    return 0
}

# =======================[ SHUTDOWN TS ]====================================

extrai_shutdown_ts() {
    local journal="$1"
    local pat="${JOURNAL_PREFIX}"'(systemd-shutdown\[1\]:|systemd\[1\]: (Shutting down|Reached target ((poweroff|reboot|halt)\.target([[:space:].]|$)|.*Shutdown))|systemd-logind(\[[0-9]+\])?: (Powering off|System is powering down))'
    # short-iso-precise: o primeiro campo contém data, hora e fuso; o segundo é o host.
    grep -iE "$pat" <<< "$journal" | awk 'NF {ts=$1} END {if (ts != "") print ts}' || true
}

# =======================[ IPMI ]==========================================

# O SEL pode usar AM/PM com offset (-03), combinação rejeitada pelo GNU date.
# Convertemos explicitamente para ISO antes de interpretar a data.
epoch_ipmi() {
    local raw="$1" d t period zone extra month day year hour minute second
    read -r d t period zone extra <<< "$raw"
    [[ -z "$extra" && "$d" =~ ^[0-9]{2}/[0-9]{2}/([0-9]{2}|[0-9]{4})$ && "$t" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 0
    IFS=/ read -r month day year <<< "$d"
    # Mesma convenção do GNU date: 00..68 => 2000..2068; 69..99 => 1969..1999.
    if [[ ${#year} -eq 2 ]]; then
        if (( 10#$year <= 68 )); then
            year=$((2000 + 10#$year))
        else
            year=$((1900 + 10#$year))
        fi
    fi
    IFS=: read -r hour minute second <<< "$t"
    hour=$((10#$hour))
    if [[ "$period" == "AM" || "$period" == "PM" ]]; then
        (( hour >= 1 && hour <= 12 )) || return 0
        hour=$((hour % 12))
        [[ "$period" == "PM" ]] && hour=$((hour + 12))
    else
        [[ -z "$zone" ]] || return 0
        zone="$period"
    fi
    if [[ "$zone" =~ ^[+-][0-9]{2}$ ]]; then
        zone="${zone}:00"
    fi
    [[ -z "$zone" || "$zone" == "UTC" || "$zone" == "GMT" || "$zone" =~ ^[+-][0-9]{2}:?[0-9]{2}$ ]] || return 0
    printf -v raw '%s-%s-%sT%02d:%s:%s%s' "$year" "$month" "$day" "$hour" "$minute" "$second" "$zone"
    LC_ALL=C date -d "$raw" +%s 2>/dev/null || true
}

filtra_ipmi_proximo() {
    local ref="$1" list="$2" ref_epoch epoch datetime line upper lower
    [[ "$IPMI_CLOCK_OK" -eq 1 && -n "$ref" && -n "$CURRENT_BOOT_EPOCH" ]] || return 0
    ref_epoch="$(LC_ALL=C date -d "$ref" +%s 2>/dev/null || true)"
    [[ "$ref_epoch" =~ ^[0-9]+$ && "$CURRENT_BOOT_EPOCH" =~ ^[0-9]+$ && "$PREVIOUS_BOOT_START_EPOCH" =~ ^[0-9]+$ ]] || return 0
    # Grandes intervalos ou relógio invertido não permitem atribuir o evento ao reboot.
    (( CURRENT_BOOT_EPOCH >= ref_epoch && ref_epoch >= PREVIOUS_BOOT_START_EPOCH && CURRENT_BOOT_EPOCH - ref_epoch <= CAUSE_WINDOW_SEC )) || return 0
    lower=$((ref_epoch - IPMI_TIME_WINDOW))
    (( lower < PREVIOUS_BOOT_START_EPOCH )) && lower="$PREVIOUS_BOOT_START_EPOCH"
    upper=$((ref_epoch + IPMI_TIME_WINDOW))
    (( upper > CURRENT_BOOT_EPOCH )) && upper="$CURRENT_BOOT_EPOCH"
    while IFS= read -r line; do
        datetime="$(awk -F'|' 'NF >= 6 {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $2" "$3}' <<< "$line")"
        [[ -n "$datetime" ]] || continue
        epoch="$(epoch_ipmi "$datetime")"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        if (( epoch >= lower && epoch < CURRENT_BOOT_EPOCH && epoch <= upper )); then
            printf '%s\n' "$line"
        fi
    done <<< "$list"
}

seleciona_falhas_ipmi() {
    local list="$1" ref="$2" ref_epoch line datetime epoch
    [[ -n "$list" && -n "$ref" ]] || return 0
    ref_epoch="$(LC_ALL=C date -d "$ref" +%s 2>/dev/null || true)"
    [[ "$ref_epoch" =~ ^[0-9]+$ ]] || return 0
    # Ordena horários interpretados; empates preservam a ordem do SEL. Cada sensor
    # e condição têm estado próprio. Recuperação antes da referência cancela a perda.
    while IFS= read -r line; do
        datetime="$(awk -F'|' 'NF >= 6 {print $2" "$3}' <<< "$line")"
        [[ -n "$datetime" ]] || continue
        epoch="$(epoch_ipmi "$datetime")"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        printf '%s|%s\n' "$epoch" "$line"
    done <<< "$list" | LC_ALL=C sort -s -t'|' -k1,1n | awk -F'|' -v ref="$ref_epoch" '
        function trim(s) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return tolower(s)}
        NF >= 7 && trim($6) ~ /ac lost|power (failure|loss)|input lost/ {
            key=trim($5) SUBSEP trim($6); state=trim($NF)
            if (state == "asserted") {
                seq++; order[seq]=key; selected[key]=seq
                lines[key]=substr($0, index($0, "|")+1)
            } else if (state == "deasserted" && $1 <= ref) {
                delete selected[key]
            }
        }
        END {for (i=1; i<=seq; i++) if (selected[order[i]] == i) print lines[order[i]]}
    '
}

valida_relogio_ipmi() {
    local raw="$1" host_epoch="$2" bmc_epoch direction magnitude
    IPMI_CLOCK_OK=0
    IPMI_CLOCK_DELTA=""
    IPMI_HOST_TIME="$(LC_ALL=C date -d "@$host_epoch" '+%Y-%m-%dT%H:%M:%S%:z')"
    bmc_epoch="$(epoch_ipmi "$raw")"
    if [[ ! "$bmc_epoch" =~ ^-?[0-9]+$ ]]; then
        printf 'Aviso: horário do BMC indisponível ou não interpretável: %s; SEL sem correlação.\n' "${raw:-vazio}" >&2
        return 0
    fi
    if [[ ! "$raw" =~ ([+-][0-9]{2}(:?[0-9]{2})?|UTC|GMT)[[:space:]]*$ ]]; then
        echo "Aviso: horário BMC sem fuso explícito; assumido o fuso do host." >&2
    fi
    IPMI_CLOCK_DELTA=$((host_epoch - bmc_epoch))
    if (( IPMI_CLOCK_DELTA >= -IPMI_CLOCK_TOLERANCE && IPMI_CLOCK_DELTA <= IPMI_CLOCK_TOLERANCE )); then
        IPMI_CLOCK_OK=1
    else
        direction="atrasado"
        (( IPMI_CLOCK_DELTA < 0 )) && direction="adiantado"
        magnitude="${IPMI_CLOCK_DELTA#-}"
        printf 'Aviso: BMC %s %s segundos em relação ao host (%s); tolerância de %ss. SEL apenas como histórico.\n' \
            "$direction" "$magnitude" "$IPMI_HOST_TIME" "$IPMI_CLOCK_TOLERANCE" >&2
        echo "Os horários históricos não serão deslocados automaticamente; confira relógio/fuso do BMC." >&2
    fi
    return 0
}

coleta_ipmi() {
    IPMI_AVAILABLE=0
    IPMI_CLOCK_OK=0
    IPMI_CLOCK_DELTA=""
    IPMI_HOST_TIME=""
    IPMI_SEL_NEAR=""
    IPMI_SEL_TIME=""
    IPMI_SEL_LIST=""
    command -v ipmitool >/dev/null 2>&1 || return 0
    if command -v modprobe >/dev/null 2>&1; then
        timeout -k 3s 10s modprobe ipmi_si >/dev/null 2>&1 || true
        timeout -k 3s 10s modprobe ipmi_devintf >/dev/null 2>&1 || true
    fi
    echo "Consultando IPMI: até ${IPMI_TIMEOUT}s para o relógio e ${IPMI_LIST_TIMEOUT}s para o SEL..." >&2
    if ! IPMI_SEL_TIME="$(LC_ALL=C timeout -k 5s "${IPMI_TIMEOUT}s" ipmitool -I open sel time get 2>/dev/null)"; then
        IPMI_SEL_TIME=""
    fi
    # Compara antes da consulta SEL, que pode levar até um minuto.
    valida_relogio_ipmi "$IPMI_SEL_TIME" "$(date +%s)"
    # Descartamos saída parcial em timeout/erro; não equivale a um SEL completo.
    if ! IPMI_SEL_LIST="$(LC_ALL=C timeout -k 5s "${IPMI_LIST_TIMEOUT}s" ipmitool -I open sel list last 50 2>/dev/null)"; then
        IPMI_SEL_LIST=""
        echo "Aviso: IPMI não disponível ou consulta SEL falhou/expirou." >&2
        return 0
    fi
    IPMI_AVAILABLE=1
    IPMI_SEL_NEAR="$(filtra_ipmi_proximo "$REF_TS" "$IPMI_SEL_LIST")"
}

# =======================[ LINHA DO TEMPO ]================================

mostra_linha_tempo() {
    local shutdown_ts="$1"
    local boot_end_ts="$2"

    echo -e "${C_BOLD}${C_CYAN}Linha do tempo:${C_RESET}"
    echo -e "${C_BOLD}Boot atual:${C_RESET}"
    if uptime -s >/dev/null 2>&1; then
        uptime -s
    else
        uptime || true
    fi

    if command -v who >/dev/null 2>&1; then
        echo "who -b: $(who -b 2>/dev/null || true)"
    fi

    if [[ -n "$shutdown_ts" ]]; then
        echo "Shutdown no boot anterior: $shutdown_ts"
    else
        echo "Shutdown no boot anterior: (não encontrado)"
        if [[ -n "$boot_end_ts" ]]; then
            echo "Último log do boot anterior: $boot_end_ts"
        fi
    fi

    if [[ "$MODE" == "FULL" ]]; then
        if [[ "$IPMI_AVAILABLE" -eq 1 ]]; then
            echo "IPMI SEL time: ${IPMI_SEL_TIME:-indisponível}"
            if [[ -n "$IPMI_HOST_TIME" ]]; then
                echo "Horário do host na consulta BMC: $IPMI_HOST_TIME"
            fi
            if [[ -n "$IPMI_CLOCK_DELTA" ]]; then
                echo "Diferença host - BMC: ${IPMI_CLOCK_DELTA}s (positivo = BMC atrasado)"
            fi
            if [[ -n "$IPMI_SEL_NEAR" ]]; then
                echo "Eventos IPMI próximos à referência (limitados ao início do boot atual):"
                echo "$IPMI_SEL_NEAR"
            else
                echo "SEL histórico (até 50 eventos; não usado como causa sem correlação):"
                echo "$IPMI_SEL_LIST"
            fi
        else
            echo "IPMI não disponível."
        fi
    fi

    echo
}

# =======================[ TRECHO FINAL JOURNAL ]==========================

mostra_trecho_journal() {
    local journal="$1" lines=5
    [[ "$MODE" == "FULL" ]] && lines=25
    echo -e "${C_BOLD}${C_BLUE}====== Trecho final disponível do boot anterior ======${C_RESET}"
    if [[ -n "$journal" ]]; then
        tail -n "$lines" <<< "$journal"
    else
        echo "(Sem logs utilizáveis; isso não permite concluir que houve queda de energia.)"
    fi
    echo
}

# =======================[ SALVAR RELATÓRIO ]==============================

habilita_save() {
    [[ "$SAVE" -eq 1 ]] || return 0
    local ts
    ts="$(date +%Y-%m-%d_%H-%M-%S)"
    if ! SAVE_FILE="$(mktemp "/tmp/analise-reinicio-${HOSTNAME_SAFE}-${ts}-XXXXXX.log")"; then
        echo "Erro: não foi possível criar um relatório seguro." >&2
        exit 3
    fi
    if ! chmod 600 -- "$SAVE_FILE"; then
        echo "Erro: não foi possível garantir permissão privada no relatório." >&2
        exit 3
    fi
    exec 3>&1 4>&2
    exec > >(tee -- "$SAVE_FILE") 2>&1
    TEE_PID=$!
    echo "Gravando relatório em: $SAVE_FILE"
}

finaliza() {
    local status=$?
    trap - EXIT
    if [[ -n "$TEE_PID" ]]; then
        exec 1>&3 2>&4 3>&- 4>&-
        if ! wait "$TEE_PID"; then
            echo "Erro: falha ao gravar/exibir relatório; o arquivo pode estar incompleto." >&2
            status=3
        else
            printf 'Relatório gravado em: %s\n' "$SAVE_FILE"
        fi
    fi
    exit "$status"
}

# =======================[ HOSTNAME ]=====================================

detecta_hostname() {
    local hn=""
    if command -v hostname >/dev/null 2>&1; then
        hn="$(hostname 2>/dev/null || true)"
    fi
    if [[ -z "$hn" && -r /etc/hostname ]]; then
        hn="$(head -n 1 /etc/hostname 2>/dev/null || true)"
    fi

    if [[ -n "$hn" ]]; then
        HOSTNAME_RAW="$hn"
    else
        HOSTNAME_RAW="desconhecido"
    fi

    HOSTNAME_SAFE="$(printf '%s' "$HOSTNAME_RAW" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
    if [[ -z "$HOSTNAME_SAFE" ]]; then
        HOSTNAME_SAFE="host"
    fi
}

# ============================[ MAIN ]=====================================

main() {
    parse_args "$@"
    init_colors
    requer_root
    local dep
    for dep in timeout date awk sed grep tail head cat tr sort env mktemp chmod tee; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Erro: comando necessário ausente: $dep" >&2
            exit 3
        fi
    done
    if ! env --default-signal=PIPE true 2>/dev/null; then
        echo "Erro: é necessário GNU env com --default-signal (coreutils 8.31 ou posterior)." >&2
        exit 3
    fi
    trap finaliza EXIT
    trap 'exit 3' INT TERM PIPE
    trap 'echo "Erro inesperado durante a execução." >&2; exit 3' ERR
    set -E
    detecta_hostname
    habilita_save

    local boot_seconds
    boot_seconds="$(awk '$1 == "btime" {print $2}' /proc/stat 2>/dev/null || true)"
    [[ "$boot_seconds" =~ ^[0-9]+$ ]] && CURRENT_BOOT_EPOCH="$boot_seconds"
    echo -e "${C_BOLD}${C_MAGENTA}Modo de operação:${C_RESET} $MODE (versão $SCRIPT_VERSION)"
    echo
    mostra_info_sistema
    prepara_journal

    local journal="" journal_kernel="" journal_sistema="" aux=""
    if ! journal="$(coleta_journal_boot_anterior)"; then
        journal=""
        EXIT_CODE=3
    fi
    if ! journal_kernel="$(coleta_journal_kernel_boot_anterior)"; then
        journal_kernel=""
        EXIT_CODE=3
    fi
    if ! journal_sistema="$(coleta_journal_sistema_boot_anterior)"; then
        journal_sistema=""
        EXIT_CODE=3
    fi
    if [[ "$MODE" == "FULL" ]]; then
        aux="$(coleta_logs_aux /var/log)"
    fi
    SHUTDOWN_TS="$(extrai_shutdown_ts "$journal_sistema")"
    # Para correlação usamos recebimento; o horário de origem é só apresentação.
    REF_TS="$BOOT_END_TS"
    if [[ "$MODE" == "FULL" ]]; then
        coleta_ipmi
    fi
    analisa_reinicio "$journal" "$journal_kernel" "$aux" "$IPMI_SEL_NEAR" "$journal_sistema"
    mostra_linha_tempo "$SHUTDOWN_TS" "$BOOT_END_TS"
    mostra_boot_overview
    if [[ "$MODE" == "FULL" ]]; then
        verifica_crash_dumps
    fi
    mostra_trecho_journal "$journal"
    exit "$EXIT_CODE"
}

# Permite testes das funções sem executar coleta, carregar módulos ou exigir root.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
