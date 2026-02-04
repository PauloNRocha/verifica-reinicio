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
        C_RESET=$'\e[0m';  C_BOLD=$'\e[1m';  C_DIM=$'\e[2m'
        C_RED=$'\e[31m';   C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
        C_BLUE=$'\e[34m';  C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
        C_GRAY=$'\e[90m'
    else
        C_RESET=""; C_BOLD=""; C_DIM=""
        C_RED="";   C_GREEN=""; C_YELLOW=""
        C_BLUE="";  C_MAGENTA=""; C_CYAN=""; C_GRAY=""
    fi
}

# ========================[ GLOBALS ]======================================

MODE="FAST"
SAVE=0
SAVE_FILE=""

SCRIPT_VERSION="1.2.4"
SCRIPT_DATE="2026-02-04"

FAST_LIMIT=1500
FULL_LIMIT=8000

JOURNAL_VOLATILE=0   # 1 = journald não persistente (apenas boot atual)

BOOT_LIST_LIMIT_FAST=5
BOOT_LIST_LIMIT_FULL=15
EVID_LIMIT_FAST=5
EVID_LIMIT_FULL=12
CAUSE_WINDOW_SEC=1800
EXIT_CODE=0
CAUSE_FOUND=0

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

  --full        Executa análise profunda (usa mais fontes de log, inclusive .gz)
  --save        Salva relatório em /tmp/analise-reinicio-HOST-AAAA-MM-DD_HH-MM-SS-XXXXXX.log
  --version     Mostra a versão do script
  --help        Mostra esta ajuda

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
            --full)
                MODE="FULL"
                ;;
            --save)
                SAVE=1
                ;;
            --version)
                show_version
                ;;
            --help)
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
        . /etc/os-release
        echo "  ${PRETTY_NAME:-$ID}"
    else
        echo "  (não foi possível detectar via /etc/os-release)"
    fi
    echo "  Hostname: ${HOSTNAME_RAW}"
    echo

    echo -e "${C_BOLD}${C_CYAN}Boot atual:${C_RESET}"
    if uptime -s >/dev/null 2>&1; then
        uptime -s
    else
        uptime
    fi
    echo
}

mostra_boot_overview() {
    local limit="$BOOT_LIST_LIMIT_FAST"
    [[ "$MODE" == "FULL" ]] && limit="$BOOT_LIST_LIMIT_FULL"

    echo -e "${C_BOLD}${C_CYAN}==== HISTÓRICO DE BOOTS (journalctl --list-boots) ====${C_RESET}"
    if command -v journalctl >/dev/null 2>&1; then
        journalctl --list-boots --no-pager 2>/dev/null | tail -n "$limit" || true
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
        systemd-analyze 2>/dev/null || true
        echo
    fi
}

# =======================[ CRASH DUMPS ]===================================

verifica_crash_dumps() {
    if [[ -d /var/crash ]] && [[ -n "$(ls -A /var/crash 2>/dev/null)" ]]; then
        echo -e "${C_BOLD}${C_MAGENTA}Crash dumps encontrados em /var/crash:${C_RESET}"
        ls -lh /var/crash | head
        echo
    fi
}

# =======================[ JOURNAL PERSISTENTE ]===========================

detecta_journal_volatile() {
    # Se /var/log/journal NÃO existe mas /run/log/journal existe → modo volátil
    if [[ ! -d /var/log/journal && -d /run/log/journal ]]; then
        JOURNAL_VOLATILE=1
    else
        JOURNAL_VOLATILE=0
    fi
}

# =======================[ JOURNAL ]=======================================

coleta_journal_boot_anterior() {
    local ref_epoch="${1:-}"
    local window_sec="${2:-$CAUSE_WINDOW_SEC}"
    echo -e "${C_DIM}Coletando logs do boot anterior (journalctl -b -1)...${C_RESET}" >&2

    if ! command -v journalctl >/dev/null 2>&1; then
        if [[ "$MODE" == "FAST" ]]; then
            echo -e "${C_YELLOW}Aviso:${C_RESET} journalctl não encontrado. Use --full para tentar /var/log." >&2
        else
            echo -e "${C_YELLOW}Aviso:${C_RESET} journalctl não encontrado. Seguindo com /var/log." >&2
        fi
        return
    fi

    if ! journalctl -b -1 -n 1 >/dev/null 2>&1; then
        if [[ $JOURNAL_VOLATILE -eq 1 ]]; then
            echo -e "${C_YELLOW}Aviso:${C_RESET} journald está em modo volátil (sem logs persistentes do boot anterior)." >&2
            echo -e "${C_DIM}Para habilitar persistência, você pode executar:${C_RESET}" >&2
            echo -e "  ${C_DIM}sudo mkdir -p /var/log/journal${C_RESET}" >&2
            echo -e "  ${C_DIM}sudo systemctl restart systemd-journald${C_RESET}" >&2
        else
            echo -e "${C_YELLOW}Aviso:${C_RESET} não foi possível acessar logs do boot anterior via journalctl -b -1." >&2
        fi
        echo "" >&2
        return
    fi

    local limite="$FAST_LIMIT"
    [[ "$MODE" == "FULL" ]] && limite="$FULL_LIMIT"

    if [[ -n "$ref_epoch" ]]; then
        local since_epoch=$((ref_epoch - window_sec))
        (( since_epoch < 0 )) && since_epoch=0
        journalctl -b -1 --since "@$since_epoch" --until "@$ref_epoch" -n "$limite" --no-pager -o short-iso 2>/dev/null || true
    else
        journalctl -b -1 -n "$limite" --no-pager -o short-iso 2>/dev/null || true
    fi
}

coleta_journal_kernel_boot_anterior() {
    local ref_epoch="${1:-}"
    local window_sec="${2:-$CAUSE_WINDOW_SEC}"
    echo -e "${C_DIM}Coletando logs do kernel do boot anterior (journalctl -b -1 -k)...${C_RESET}" >&2

    if ! command -v journalctl >/dev/null 2>&1; then
        return
    fi

    if ! journalctl -b -1 -k -n 1 >/dev/null 2>&1; then
        return
    fi

    local limite="$FAST_LIMIT"
    [[ "$MODE" == "FULL" ]] && limite="$FULL_LIMIT"

    if [[ -n "$ref_epoch" ]]; then
        local since_epoch=$((ref_epoch - window_sec))
        (( since_epoch < 0 )) && since_epoch=0
        journalctl -b -1 -k --since "@$since_epoch" --until "@$ref_epoch" -n "$limite" --no-pager -o short-iso 2>/dev/null || true
    else
        journalctl -b -1 -k -n "$limite" --no-pager -o short-iso 2>/dev/null || true
    fi
}

# =======================[ LOGS AUXILIARES (/var/log) ]====================

coleta_logs_aux() {
    echo -e "${C_DIM}Varredura de logs auxiliares em /var/log...${C_RESET}" >&2

    local arquivos_text=()
    local arquivos_gz=()

    add_logs() {
        local pattern="$1"
        local f
        for f in $pattern; do
            [[ -e "$f" ]] || continue
            if [[ "$f" == *.gz ]]; then
                arquivos_gz+=("$f")
            else
                arquivos_text+=("$f")
            fi
        done
    }

    add_logs "/var/log/syslog*"
    add_logs "/var/log/kern.log*"
    add_logs "/var/log/messages*"
    add_logs "/var/log/dmesg*"

    local regex='kernel panic|fatal exception|Oops:|BUG:|hard lockup|soft lockup|watchdog: BUG|Watchdog detected|hung task|hung_task|oom-killer|out of memory|thermal.*critical|critical temperature|Machine Check Exception|hardware error|I/O error|EXT[2-4]-fs error|xfs.*error|segfault|reboot: System reboot|Restarting system|power failure|ac lost|power loss|power supply|psu|mains power|line power|power outage|brownout|\<ups\>|upsd|apcupsd'

    local saida=""
    local max_lines=10000

    if ((${#arquivos_text[@]} > 0)); then
        saida+="$(grep -siE "$regex" "${arquivos_text[@]}" 2>/dev/null | tail -n $max_lines || true)"$'\n'
    fi

    if [[ "$MODE" == "FULL" && ${#arquivos_gz[@]} -gt 0 ]]; then
        if command -v zgrep >/dev/null 2>&1; then
            saida+="$(zgrep -siE "$regex" "${arquivos_gz[@]}" 2>/dev/null | tail -n $max_lines || true)"$'\n'
        fi
    fi

    echo "$saida" | sed '/^$/d' | tail -n 120
}

# =======================[ ANÁLISE ]=======================================

analisa_reinicio() {
    local journal="$1"
    local journal_kernel="$2"
    local aux="$3"
    local journal_volatile="$4"
    local ipmi_near="$5"

    local motivo_plain=""
    local motivo_color="$C_RESET"
    local trecho=""
    local origem=""
    local segfault_evid=""
    local evid_limit="$EVID_LIMIT_FAST"
    [[ "$MODE" == "FULL" ]] && evid_limit="$EVID_LIMIT_FULL"

    local shutdown_limpo=0
    if [[ -n "$journal" ]] && grep -qiE 'systemd-shutdown\[|Shutting down\.|Reached target (Shutdown|Reboot|Power)|Powering off|System is powering down' <<< "$journal"; then
        shutdown_limpo=1
    fi

    detecta_nos_logs() {
        local LOGSOURCE="$1"
        local regex="$2"
        local label="$3"
        local color="$4"
        local src="$5"

        if [[ -z "$motivo_plain" ]] && grep -qiE "$regex" <<< "$LOGSOURCE"; then
            motivo_plain="$label"
            motivo_color="$color"
            trecho="$(grep -iE "$regex" <<< "$LOGSOURCE" | head -n "$evid_limit")"
            origem="$src"
        fi
    }

    local rx_crash='kernel panic|fatal exception|Oops:|BUG:|hard lockup|soft lockup|watchdog: BUG|Watchdog detected|hung task|hung_task'
    local rx_oom='Out of memory: Kill process|Killed process|invoked oom-killer|Memory cgroup out of memory|oom-killer|out of memory'
    local rx_thermal='thermal.*critical|critical temperature'
    local rx_hw='Machine Check Exception|hardware error'
    local rx_disk='I/O error|EXT[2-4]-fs error|xfs.*error'
    local rx_seg='segfault'
    local rx_powerkey='systemd-logind\[.*\]: (Power key pressed short|Power key pressed|Powering off|System is powering down)'
    local rx_powerloss='power failure|ac lost|power loss|power supply|psu|mains power|line power|power outage|brownout|\<ups\>|upsd|apcupsd'
    local rx_update='unattended-upgrade|dpkg:.*linux-image|apt-get.*(dist-upgrade|full-upgrade)'
    local rx_reboot='reboot: System reboot|Restarting system|machine_restart'

    local journal_focus="$journal"
    local kernel_focus="$journal_kernel"

    # Primeiro: tentar achar causa no journal do boot anterior (se existir)
    if [[ -n "$journal_focus" || -n "$kernel_focus" ]]; then
        local kernel_src="$kernel_focus"
        [[ -z "$kernel_src" ]] && kernel_src="$journal_focus"

        detecta_nos_logs "$kernel_src" "$rx_crash" "Kernel panic / travamento"            "$C_RED"    "journal"
        detecta_nos_logs "$journal_focus" "$rx_oom"   "Falta de memória (OOM)"               "$C_RED"    "journal"
        detecta_nos_logs "$journal_focus" "$rx_powerloss" "Perda/instabilidade de energia (rede elétrica/UPS/PSU)" "$C_RED" "journal"
        detecta_nos_logs "$journal_focus" "$rx_powerkey"  "Shutdown via ACPI/Power key (possível glitch elétrico, UPS, ou botão)" "$C_YELLOW" "journal"
        detecta_nos_logs "$journal_focus" "$rx_thermal"   "Problema térmico (temperatura crítica)" "$C_RED"  "journal"
        detecta_nos_logs "$journal_focus" "$rx_hw"        "Erro de hardware (MCE)"               "$C_RED"    "journal"
        detecta_nos_logs "$journal_focus" "$rx_disk"      "Erro de disco/filesystem"             "$C_RED"    "journal"
        if [[ -z "$segfault_evid" ]] && grep -qiE "$rx_seg" <<< "$journal_focus"; then
            segfault_evid="$(grep -iE "$rx_seg" <<< "$journal_focus" | head -n "$evid_limit")"
        fi
        if [[ $shutdown_limpo -eq 1 ]]; then
            detecta_nos_logs "$journal_focus" "$rx_update" "Reboot possivelmente causado por atualização (apt/dpkg)" "$C_GREEN" "journal"
        fi
        detecta_nos_logs "$journal_focus" "$rx_reboot"   "Reinício normal (sequência registrada)" "$C_GREEN" "journal"
    fi

    # Segundo: logs auxiliares de /var/log, mas APENAS se não achamos motivo antes.
    # Tratados como "causa provável" por poderem ser antigos.
    if [[ -z "$motivo_plain" && -n "$aux" && "$MODE" == "FULL" ]]; then
        detecta_nos_logs "$aux" "$rx_crash"     "Kernel panic / travamento (logs auxiliares)" "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_oom"       "Falta de memória (OOM) (logs auxiliares)"    "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_powerloss" "Perda/instabilidade de energia (logs auxiliares)" "$C_RED" "aux"
        detecta_nos_logs "$aux" "$rx_powerkey"  "Shutdown via ACPI/Power key (logs auxiliares)" "$C_YELLOW" "aux"
        detecta_nos_logs "$aux" "$rx_thermal"   "Problema térmico (logs auxiliares)"         "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_hw"        "Erro de hardware (MCE) (logs auxiliares)"   "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_disk"      "Erro de disco/filesystem (logs auxiliares)" "$C_RED"    "aux"
        if [[ -z "$segfault_evid" ]] && grep -qiE "$rx_seg" <<< "$aux"; then
            segfault_evid="$(grep -iE "$rx_seg" <<< "$aux" | head -n "$evid_limit")"
        fi
        detecta_nos_logs "$aux" "$rx_reboot"    "Reinício normal (encontrado em logs auxiliares)" "$C_GREEN"  "aux"
    fi

    if [[ -n "$ipmi_near" ]] && grep -qiE "$rx_powerloss" <<< "$ipmi_near"; then
        if [[ -z "$motivo_plain" \
            || "$motivo_plain" == "Shutdown via ACPI/Power key (possível glitch elétrico, UPS, ou botão)" \
            || "$motivo_plain" == "Reinício normal (sequência registrada)" \
            || "$motivo_plain" == "Reboot possivelmente causado por atualização (apt/dpkg)" \
            || "$motivo_plain" == "Reinício normal (encontrado em logs auxiliares)" \
            || "$motivo_plain" == "Shutdown via ACPI/Power key (logs auxiliares)" ]]; then
            motivo_plain="Perda/instabilidade de energia (rede elétrica/UPS/PSU)"
            motivo_color="$C_RED"
            trecho="$(grep -iE "$rx_powerloss" <<< "$ipmi_near" | head -n "$evid_limit")"
            origem="ipmi"
        fi
    fi

    echo -e "${C_BOLD}${C_GREEN}=========== ANÁLISE DO MOTIVO DO REINÍCIO ==========${C_RESET}"

    if [[ -n "$motivo_plain" ]]; then
        echo -e "Motivo detectado: ${motivo_color}${motivo_plain}${C_RESET}"
        if [[ "$origem" == "aux" ]]; then
            echo -e "${C_DIM}(Baseado em logs auxiliares de /var/log — podem incluir eventos mais antigos, não apenas o último reboot.)${C_RESET}"
        elif [[ "$origem" == "ipmi" ]]; then
            echo -e "${C_DIM}(Baseado em eventos IPMI próximos ao shutdown.)${C_RESET}"
        fi
        echo
        echo -e "${C_BOLD}Evidência:${C_RESET}"
        echo "$trecho"
        CAUSE_FOUND=1

    elif [[ $shutdown_limpo -eq 1 ]]; then
        echo -e "Reinício normal: sequência de desligamento detectada no journal (systemd-shutdown / Shutting down)."
        CAUSE_FOUND=1

    else
        if [[ $journal_volatile -eq 1 && -z "$journal" ]]; then
            echo -e "${C_YELLOW}Journald em modo volátil:${C_RESET} não há logs persistentes do boot anterior."
            if [[ "$MODE" == "FULL" && -n "$aux" ]]; then
                echo "Foram analisados logs auxiliares em /var/log, mas não foi possível determinar com segurança o motivo do último reboot."
            fi
            echo -e "Resultado: ${C_YELLOW}INCONCLUSIVO por falta de logs persistentes.${C_RESET}"
            EXIT_CODE=2
        else
            if [[ -z "$journal" && -z "$aux" ]]; then
                echo -e "${C_YELLOW}Inconclusivo:${C_RESET} não há logs suficientes no journal nem em /var/log."
                EXIT_CODE=2
            elif [[ -n "$journal" && $shutdown_limpo -eq 0 ]]; then
                echo -e "${C_RED}Reinício possivelmente abrupto:${C_RESET} não há sequência normal de shutdown no journal."
                echo "Provável travamento, reset físico ou queda de energia."
                CAUSE_FOUND=1
            else
                echo -e "${C_YELLOW}Inconclusivo:${C_RESET} não foi possível identificar um motivo claro com os logs disponíveis."
                EXIT_CODE=2
            fi
        fi
    fi

    echo -e "${C_BOLD}${C_GREEN}====================================================${C_RESET}"
    echo

    # Se não encontramos um motivo conclusivo, mas temos logs auxiliares,
    # mostramos apenas como INDÍCIOS (principalmente útil em journald volátil).
    if [[ -z "$motivo_plain" ]]; then
        if [[ -n "$segfault_evid" ]]; then
            echo "------ Indícios no journal (boot anterior) ------"
            echo "$segfault_evid"
            echo "===================================================="
            echo
        fi
        if [[ -n "$aux" ]]; then
            echo "------ Indícios em logs históricos (/var/log) ------"
            echo "$aux"
            echo "(Atenção: estes eventos podem ser antigos e NÃO estão sendo usados como causa direta do último reboot.)"
            echo "===================================================="
            echo
        fi
    fi
}

# =======================[ SHUTDOWN TS ]====================================

extrai_shutdown_ts() {
    local journal="$1"
    local pat='systemd-shutdown\[|Shutting down\.|Reached target (Shutdown|Reboot|Power)|Powering off|System is powering down'

    local linha
    linha="$(grep -iE "$pat" <<< "$journal" | tail -n 1 || true)"

    if [[ -n "$linha" ]]; then
        awk '{print $1" "$2}' <<< "$linha"
    fi
}

extrai_ultimo_ts() {
    local journal="$1"
    local linha
    linha="$(tail -n 1 <<< "$journal" 2>/dev/null || true)"
    if [[ -n "$linha" ]]; then
        awk '{print $1" "$2}' <<< "$linha"
    fi
}

extrai_fim_boot_list() {
    local linha
    if ! command -v journalctl >/dev/null 2>&1; then
        return
    fi
    linha="$(journalctl --list-boots --no-pager 2>/dev/null | awk '$1=="-1"{print $0}' | tail -n 1 || true)"
    if [[ -n "$linha" ]]; then
        awk '{if (NF>=8) {print $(NF-2)" "$(NF-1)" "$NF}}' <<< "$linha"
    fi
}

# =======================[ IPMI ]==========================================

filtra_ipmi_proximo() {
    local shutdown_ts="$1"
    local list="$2"

    [[ -z "$shutdown_ts" || -z "$list" ]] && return 0

    local shutdown_epoch
    shutdown_epoch="$(LC_ALL=C date -d "$shutdown_ts" +%s 2>/dev/null || true)"
    [[ -z "$shutdown_epoch" ]] && return 0

    local window=900
    local out=""

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local datetime
        datetime="$(awk -F'|' '{gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $3); print $2" "$3}' <<< "$line")"
        [[ -z "$datetime" ]] && continue
        local epoch
        epoch="$(LC_ALL=C date -d "$datetime" +%s 2>/dev/null || true)"
        [[ -z "$epoch" ]] && continue
        local diff=$((epoch - shutdown_epoch))
        diff=${diff#-}
        if (( diff <= window )); then
            out+="$line"$'\n'
        fi
    done <<< "$list"

    echo "$out"
}

coleta_ipmi() {
    if ! command -v ipmitool >/dev/null 2>&1; then
        IPMI_AVAILABLE=0
        return 0
    fi

    IPMI_AVAILABLE=1

    modprobe ipmi_si >/dev/null 2>&1 || true
    modprobe ipmi_devintf >/dev/null 2>&1 || true

    if command -v timeout >/dev/null 2>&1; then
        IPMI_SEL_TIME="$(timeout 8s ipmitool sel time get 2>/dev/null || true)"
        IPMI_SEL_LIST="$(timeout 12s ipmitool sel list last 50 2>/dev/null || true)"
        if [[ -z "$IPMI_SEL_LIST" ]]; then
            IPMI_SEL_LIST="$(timeout 12s ipmitool sel list 2>/dev/null | tail -n 50 || true)"
        fi
    else
        IPMI_SEL_TIME="$(ipmitool sel time get 2>/dev/null || true)"
        IPMI_SEL_LIST="$(ipmitool sel list last 50 2>/dev/null || true)"
        if [[ -z "$IPMI_SEL_LIST" ]]; then
            IPMI_SEL_LIST="$(ipmitool sel list 2>/dev/null | tail -n 50 || true)"
        fi
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
                echo "Eventos IPMI próximos ao shutdown:"
                echo "$IPMI_SEL_NEAR"
            else
                echo "Eventos IPMI recentes (últimos 50):"
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
    local journal="$1"
    local journal_volatile="$2"

    echo -e "${C_BOLD}${C_BLUE}====== Trecho final dos logs do boot anterior (journal) ======${C_RESET}"
    if [[ -n "$journal" ]]; then
        tail -n 25 <<< "$journal"
    else
        if [[ $journal_volatile -eq 1 ]]; then
            echo "(Nenhum log do boot anterior: journald em modo volátil, só mantém o boot atual.)"
        else
            echo "(Nenhum log disponível para o boot anterior via journalctl -b -1.)"
        fi
    fi
    echo
}

# =======================[ SALVAR RELATÓRIO ]==============================

habilita_save() {
    if [[ "$SAVE" -eq 1 ]]; then
        local ts
        ts="$(date +%Y-%m-%d_%H-%M-%S)"
        if command -v mktemp >/dev/null 2>&1; then
            SAVE_FILE="$(mktemp "/tmp/analise-reinicio-${HOSTNAME_SAFE}-${ts}-XXXXXX.log")"
        else
            SAVE_FILE="/tmp/analise-reinicio-${HOSTNAME_SAFE}-${ts}-XXXXXX.log"
            : > "$SAVE_FILE"
        fi
        chmod 600 "$SAVE_FILE" 2>/dev/null || true
        # Captura stdout e stderr
        exec > >(tee "$SAVE_FILE") 2>&1
        echo -e "${C_GREEN}Relatório será salvo em:${C_RESET} $SAVE_FILE"
        echo
    fi
}

# =======================[ HOSTNAME ]=====================================

detecta_hostname() {
    local hn=""
    if command -v hostname >/dev/null 2>&1; then
        hn="$(hostname 2>/dev/null || true)"
    elif [[ -r /etc/hostname ]]; then
        hn="$(head -n 1 /etc/hostname 2>/dev/null || true)"
    fi

    if [[ -n "$hn" ]]; then
        HOSTNAME_RAW="$hn"
    else
        HOSTNAME_RAW="desconhecido"
    fi

    HOSTNAME_SAFE="$(echo "$HOSTNAME_RAW" | tr -c 'A-Za-z0-9._-' '_' | sed 's/^_*//;s/_*$//')"
    if [[ -z "$HOSTNAME_SAFE" ]]; then
        HOSTNAME_SAFE="host"
    fi
}

# ============================[ MAIN ]=====================================

main() {
    parse_args "$@"
    init_colors
    requer_root
    detecta_hostname
    habilita_save

    detecta_journal_volatile

    echo -e "${C_BOLD}${C_MAGENTA}Modo de operação:${C_RESET} $MODE"
    echo

    mostra_info_sistema
    mostra_boot_overview
    verifica_crash_dumps

    local journal journal_kernel aux
    BOOT_END_TS="$(extrai_fim_boot_list)"
    REF_TS="$BOOT_END_TS"
    local ref_epoch=""
    if [[ -n "$REF_TS" ]]; then
        ref_epoch="$(LC_ALL=C date -d "$REF_TS" +%s 2>/dev/null || true)"
    fi
    journal="$(coleta_journal_boot_anterior "$ref_epoch" "$CAUSE_WINDOW_SEC")"
    journal_kernel="$(coleta_journal_kernel_boot_anterior "$ref_epoch" "$CAUSE_WINDOW_SEC")"

    if [[ "$MODE" == "FULL" ]]; then
        aux="$(coleta_logs_aux)"
    else
        aux=""
    fi

    SHUTDOWN_TS="$(extrai_shutdown_ts "$journal")"
    [[ -z "$BOOT_END_TS" ]] && BOOT_END_TS="$(extrai_ultimo_ts "$journal")"
    REF_TS="$SHUTDOWN_TS"
    [[ -z "$REF_TS" ]] && REF_TS="$BOOT_END_TS"
    if [[ "$MODE" == "FULL" ]]; then
        coleta_ipmi
    fi

    analisa_reinicio "$journal" "$journal_kernel" "$aux" "$JOURNAL_VOLATILE" "$IPMI_SEL_NEAR"
    mostra_linha_tempo "$SHUTDOWN_TS" "$BOOT_END_TS"
    mostra_trecho_journal "$journal" "$JOURNAL_VOLATILE"

    if [[ "$SAVE" -eq 1 ]]; then
        echo "Relatório salvo em: $SAVE_FILE"
    fi

    if [[ "$EXIT_CODE" -eq 0 && "$CAUSE_FOUND" -eq 1 ]]; then
        exit 0
    fi
    if [[ "$EXIT_CODE" -eq 0 ]]; then
        exit 2
    fi
    exit "$EXIT_CODE"
}

main "$@"
