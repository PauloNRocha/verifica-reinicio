#!/usr/bin/env bash
#
# Ferramenta para analisar o motivo do último reinício em sistemas Linux
# (Debian/Ubuntu/AlmaLinux/RHEL/Rocky, inclusive ambientes com cPanel).
#
# Autor: Paulo Rocha (PauloNRocha)
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
    if [[ -t 1 ]]; then
        C_RESET=$'\e[0m';  C_BOLD=$'\e[1m'
        C_RED=$'\e[31m';   C_GREEN=$'\e[32m'
        C_BLUE=$'\e[34m';  C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
    else
        C_RESET=""; C_BOLD=""
        C_RED="";   C_GREEN=""
        C_BLUE="";  C_MAGENTA=""; C_CYAN=""
    fi
}

# ========================[ GLOBALS ]======================================

MODE="FAST"
SAVE=0
SAVE_FILE=""

SCRIPT_VERSION="1.3.0"
SCRIPT_DATE="2026-09-21"

FAST_LIMIT=1500
FULL_LIMIT=8000

BOOT_LIST=""
PREVIOUS_BOOT_ID=""
BOOT_END_EPOCH=""
CURRENT_BOOT_EPOCH=""
JOURNAL_TIMEOUT=30
IPMI_TIMEOUT=30
IPMI_LIST_TIMEOUT=60
IPMI_TIME_WINDOW=900
IPMI_CLOCK_TOLERANCE=300
IPMI_CLOCK_OK=0
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

prepara_journal() {
    BOOT_LIST=""
    PREVIOUS_BOOT_ID=""
    BOOT_END_EPOCH=""
    BOOT_END_TS=""
    if ! command -v journalctl >/dev/null 2>&1; then
        echo "Aviso: journalctl não encontrado. O modo FULL pode mostrar indícios em /var/log." >&2
        return 0
    fi
    local current_id last_line
    if ! BOOT_LIST="$(LC_ALL=C timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl --list-boots --no-pager 2>/dev/null)"; then
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
    if ! last_line="$(LC_ALL=C timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl -b "$PREVIOUS_BOOT_ID" -n 1 -o short-unix --quiet --no-pager 2>/dev/null)"; then
        EXIT_CODE=3
        return 0
    fi
    BOOT_END_EPOCH="$(awk 'NF {print $1; exit}' <<< "$last_line")"
    if [[ ! "$BOOT_END_EPOCH" =~ ^[0-9]+\.[0-9]{6}$ ]]; then
        BOOT_END_EPOCH=""
        echo "Aviso: timestamp inválido; não será feita análise sem janela temporal." >&2
        return 0
    fi
    BOOT_END_TS="$(LC_ALL=C date -d "@$BOOT_END_EPOCH" '+%Y-%m-%dT%H:%M:%S.%6N%:z')"
}

coleta_journal_boot_anterior() {
    local kind="${1:-geral}" limite="$FAST_LIMIT" since_epoch data
    local extra=()
    [[ "$MODE" == "FULL" ]] && limite="$FULL_LIMIT"
    [[ "$kind" == "kernel" ]] && extra=(-k)
    [[ -n "$BOOT_END_EPOCH" && -n "$PREVIOUS_BOOT_ID" ]] || return 0
    since_epoch=$(( ${BOOT_END_EPOCH%%.*} - CAUSE_WINDOW_SEC ))
    (( since_epoch < 0 )) && since_epoch=0
    echo "Coletando journal ($kind), janela de ${CAUSE_WINDOW_SEC}s, até $BOOT_END_TS..." >&2
    if ! data="$(LC_ALL=C timeout -k 3s "${JOURNAL_TIMEOUT}s" journalctl -b "$PREVIOUS_BOOT_ID" "${extra[@]}" \
        --since "@$since_epoch" --until "@$BOOT_END_EPOCH" -n "$limite" \
        --quiet --no-pager -o short-iso-precise 2>/dev/null)"; then
        echo "Erro: falha ou timeout na coleta do journal ($kind)." >&2
        return 3
    fi
    if (( $(awk 'END {print NR}' <<< "$data") >= limite )); then
        echo "Aviso: limite de $limite registros atingido; a janela pode estar incompleta." >&2
    fi
    printf '%s\n' "$data"
}

coleta_journal_kernel_boot_anterior() {
    coleta_journal_boot_anterior kernel
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
    local f data matches count=0 found=0
    local log_dir="${1:-/var/log}"
    for f in "$log_dir"/syslog* "$log_dir"/kern.log* "$log_dir"/messages* "$log_dir"/dmesg*;
    do
        [[ -f "$f" && -r "$f" && ! -L "$f" ]] || continue
        if (( count >= AUX_MAX_FILES )); then
            echo "Aviso: limite de $AUX_MAX_FILES arquivos históricos atingido." >&2
            break
        fi
        count=$((count + 1))
        if [[ "$f" == *.gz ]]; then
            command -v gzip >/dev/null 2>&1 || continue
            # head limita bytes descompactados; SIGPIPE é esperado nesta amostragem.
            data="$(timeout -k 2s "${AUX_TIMEOUT}s" gzip -cd -- "$f" 2>/dev/null | head -c "$AUX_MAX_BYTES" || true)"
        else
            data="$(timeout -k 2s "${AUX_TIMEOUT}s" tail -c "$AUX_MAX_BYTES" -- "$f" 2>/dev/null || true)"
        fi
        matches="$(filtra_indicios "$data")"
        if [[ -n "$matches" ]]; then
            printf '%s\n' "------ $f (amostra parcial; eventos sem correlação temporal) ------"
            printf '%s\n' "$matches"
            found=1
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        echo "Nenhum evento relevante encontrado nas amostras históricas disponíveis." >&2
    fi
}

# =======================[ ANÁLISE ]=======================================

analisa_reinicio() {
    local journal="$1" kernel="$2" aux="$3" ipmi="$4"
    local limite="$EVID_LIMIT_FAST" panic acpi power ipmi_power reboot shutdown clues
    [[ "$MODE" == "FULL" ]] && limite="$EVID_LIMIT_FULL"
    local rx_power='(power (failure|loss|outage)|AC lost|brownout|mains.*(lost|fail)|UPS.*on battery|power supply.*(failure|input lost))'
    # Exigimos emissor do kernel para panic; OOM/Oops/lockup isolados são indícios.
    panic="$(grep -iE -m "$limite" 'kernel:.*Kernel panic' <<< "$kernel" || true)"
    acpi="$(grep -iE -m "$limite" 'systemd-logind(\[[0-9]+\])?: (Power key pressed|Powering off|System is powering down)' <<< "$journal" || true)"
    power="$(grep -iE "$rx_power" <<< "$journal" | grep -viE 'restored|recovered|Deasserted|no power (loss|failure)|test|simulat' | sed -n "1,${limite}p" || true)"
    ipmi_power="$(awk -F'|' 'tolower($NF) ~ /^[[:space:]]*asserted[[:space:]]*$/ && tolower($5) ~ /ac lost|power (failure|loss)|input lost/ {print}' <<< "$ipmi" | sed -n "1,${limite}p")"
    reboot="$(grep -iE -m "$limite" '(kernel:.*reboot: (Restarting system|System reboot)|systemd-shutdown\[[0-9]+\]: (Rebooting|Powering off))' <<< "$journal" || true)"
    shutdown="$(extrai_shutdown_ts "$journal")"
    clues="$(filtra_indicios "$kernel" "$limite")"

    echo -e "${C_BOLD}${C_GREEN}=========== ANÁLISE DO MOTIVO DO REINÍCIO ==========${C_RESET}"
    local result=2
    if [[ -n "$panic" ]]; then
        echo "Evidência forte: Kernel panic / travamento."
        printf '%s\n' "$panic"
        result=0
        if [[ -n "$ipmi_power" ]]; then
            echo "Há também falha elétrica correlacionada no SEL; pode haver causas concorrentes."
            printf '%s\n' "$ipmi_power"
        fi
    elif [[ -n "$ipmi_power" ]]; then
        echo "Causa provável: Perda/instabilidade de energia (rede elétrica/UPS/PSU)."
        echo "Falha elétrica ativa registrada perto do fim do boot; não comprova perda de todas as fontes."
        printf '%s\n' "$ipmi_power"
        result=0
    elif [[ -n "$acpi" ]]; then
        echo "Mecanismo registrado: Shutdown via ACPI/Power key (possível glitch elétrico, UPS, ou botão)."
        echo "O registro não identifica ação humana nem confirma a causa elétrica."
        printf '%s\n' "$acpi"
        result=0
    elif [[ -n "$reboot" ]]; then
        echo "Sequência de reinício/desligamento registrada; causa da solicitação não determinada."
        printf '%s\n' "$reboot"
        result=0
    else
        echo "Motivo não conclusivo."
        if [[ -n "$shutdown" ]]; then
            echo "Há início de desligamento, mas não há evidência suficiente de conclusão ou causa."
        elif [[ -n "$journal" ]]; then
            echo "Sem sequência de desligamento na amostra: interrupção abrupta ou logs incompletos são possíveis."
        else
            echo "Sem registros utilizáveis do boot anterior para determinar a causa."
        fi
    fi
    if [[ -n "$power" ]]; then
        echo "------ Indícios elétricos no journal (exigem confirmação) ------"
        printf '%s\n' "$power"
    fi
    if [[ -n "$acpi" && -n "$ipmi_power" ]]; then
        echo "------ Sequência ACPI associada ------"
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
    local pat='(systemd-shutdown\[[0-9]+\]:|systemd\[1\]: (Shutting down|Reached target .*Shutdown)|systemd-logind(\[[0-9]+\])?: (Powering off|System is powering down))'
    # short-iso-precise: o primeiro campo contém data, hora e fuso; o segundo é o host.
    grep -iE "$pat" <<< "$journal" | awk 'NF {ts=$1} END {if (ts != "") print ts}' || true
}

# =======================[ IPMI ]==========================================

# O SEL pode usar AM/PM com offset (-03), combinação rejeitada pelo GNU date.
# Convertemos explicitamente para ISO antes de interpretar a data.
epoch_ipmi() {
    local raw="$1" d t period zone extra month day year hour minute second
    read -r d t period zone extra <<< "$raw"
    [[ -z "$extra" && "$d" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ && "$t" =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || return 0
    IFS=/ read -r month day year <<< "$d"
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
    local ref="$1" list="$2" ref_epoch epoch datetime line upper
    [[ "$IPMI_CLOCK_OK" -eq 1 && -n "$ref" && -n "$CURRENT_BOOT_EPOCH" ]] || return 0
    ref_epoch="$(LC_ALL=C date -d "$ref" +%s 2>/dev/null || true)"
    [[ "$ref_epoch" =~ ^[0-9]+$ && "$CURRENT_BOOT_EPOCH" =~ ^[0-9]+$ ]] || return 0
    # Grandes intervalos ou relógio invertido não permitem atribuir o evento ao reboot.
    (( CURRENT_BOOT_EPOCH >= ref_epoch && CURRENT_BOOT_EPOCH - ref_epoch <= CAUSE_WINDOW_SEC )) || return 0
    upper=$((ref_epoch + IPMI_TIME_WINDOW))
    (( upper > CURRENT_BOOT_EPOCH )) && upper="$CURRENT_BOOT_EPOCH"
    while IFS= read -r line; do
        datetime="$(awk -F'|' 'NF >= 6 {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $2" "$3}' <<< "$line")"
        [[ -n "$datetime" ]] || continue
        epoch="$(epoch_ipmi "$datetime")"
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        if (( epoch >= ref_epoch - IPMI_TIME_WINDOW && epoch <= upper )); then
            printf '%s\n' "$line"
        fi
    done <<< "$list"
}

coleta_ipmi() {
    IPMI_AVAILABLE=0
    IPMI_CLOCK_OK=0
    IPMI_SEL_NEAR=""
    command -v ipmitool >/dev/null 2>&1 || return 0
    if command -v modprobe >/dev/null 2>&1; then
        timeout -k 3s 10s modprobe ipmi_si >/dev/null 2>&1 || true
        timeout -k 3s 10s modprobe ipmi_devintf >/dev/null 2>&1 || true
    fi
    echo "Consultando IPMI: até ${IPMI_TIMEOUT}s para o relógio e ${IPMI_LIST_TIMEOUT}s para o SEL..." >&2
    if ! IPMI_SEL_TIME="$(LC_ALL=C timeout -k 5s "${IPMI_TIMEOUT}s" ipmitool -I open sel time get 2>/dev/null)"; then
        IPMI_SEL_TIME=""
    fi
    # Descartamos saída parcial em timeout/erro; não equivale a um SEL completo.
    if ! IPMI_SEL_LIST="$(LC_ALL=C timeout -k 5s "${IPMI_LIST_TIMEOUT}s" ipmitool -I open sel list last 50 2>/dev/null)"; then
        IPMI_SEL_LIST=""
        echo "Aviso: IPMI não disponível ou consulta SEL falhou/expirou." >&2
        return 0
    fi
    IPMI_AVAILABLE=1
    echo "Aviso: SEL sem fuso explícito usa o fuso do host; confira a configuração do BMC." >&2
    local bmc_epoch now delta
    bmc_epoch="$(epoch_ipmi "$IPMI_SEL_TIME")"
    now="$(date +%s)"
    if [[ "$bmc_epoch" =~ ^[0-9]+$ ]]; then
        delta=$((now - bmc_epoch))
        if (( delta >= -IPMI_CLOCK_TOLERANCE && delta <= IPMI_CLOCK_TOLERANCE )); then
            IPMI_CLOCK_OK=1
        fi
    fi
    if [[ "$IPMI_CLOCK_OK" -eq 0 ]]; then
        echo "Aviso: relógio BMC inválido ou divergente; SEL apenas como histórico, sem diagnóstico." >&2
    fi
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
    for dep in timeout date awk sed grep tail head cat tr mktemp chmod tee; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Erro: comando necessário ausente: $dep" >&2
            exit 3
        fi
    done
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
    mostra_boot_overview
    if [[ "$MODE" == "FULL" ]]; then
        verifica_crash_dumps
    fi

    local journal="" journal_kernel="" aux=""
    if ! journal="$(coleta_journal_boot_anterior)"; then
        journal=""
        EXIT_CODE=3
    fi
    if ! journal_kernel="$(coleta_journal_kernel_boot_anterior)"; then
        journal_kernel=""
        EXIT_CODE=3
    fi
    if [[ "$MODE" == "FULL" ]]; then
        aux="$(coleta_logs_aux)"
    fi
    SHUTDOWN_TS="$(extrai_shutdown_ts "$journal")"
    REF_TS="${SHUTDOWN_TS:-$BOOT_END_TS}"
    if [[ "$MODE" == "FULL" ]]; then
        coleta_ipmi
    fi
    analisa_reinicio "$journal" "$journal_kernel" "$aux" "$IPMI_SEL_NEAR"
    mostra_linha_tempo "$SHUTDOWN_TS" "$BOOT_END_TS"
    mostra_trecho_journal "$journal"
    exit "$EXIT_CODE"
}

# Permite testes das funções sem executar coleta, carregar módulos ou exigir root.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
