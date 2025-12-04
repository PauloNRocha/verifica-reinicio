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

set -o pipefail

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

FAST_LIMIT=1500
FULL_LIMIT=8000

JOURNAL_VOLATILE=0   # 1 = journald não persistente (apenas boot atual)

# =======================[ AJUDA ]=========================================

show_help() {
cat << EOF
${C_BOLD}Uso:${C_RESET} sudo $0 [opções]

Opções disponíveis:

  --full        Executa análise profunda (usa mais fontes de log, inclusive .gz)
  --save        Salva relatório em /tmp/analise-reinicio-AAAA-MM-DD_HH-MM-SS.log
  --help        Mostra esta ajuda

Modo padrão (sem flags):
  * FAST → Análise rápida usando journalctl + padrões essenciais.

Exemplos:
  sudo $0
  sudo $0 --full
  sudo $0 --save
  sudo $0 --full --save
EOF
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
            --help)
                init_colors
                show_help
                ;;
            *)
                init_colors
                echo -e "${C_RED}ERRO:${C_RESET} opção desconhecida: $arg" >&2
                show_help
                ;;
        esac
    done
}

# =======================[ ROOT CHECK ]====================================

requer_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${C_RED}ERRO:${C_RESET} este script precisa ser executado como root."
        exit 1
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
    echo

    echo -e "${C_BOLD}${C_CYAN}Boot atual:${C_RESET}"
    if uptime -s >/dev/null 2>&1; then
        uptime -s
    else
        uptime
    fi
    echo
}

mostra_boot_logs() {
    echo -e "${C_BOLD}${C_CYAN}==== ÚLTIMOS EVENTOS DE BOOT/REINÍCIO ====${C_RESET}"
    if command -v last >/dev/null 2>&1; then
        # -n para evitar ler wtmp gigantesco
        last -x -n 12
    else
        echo "Comando 'last' não encontrado."
    fi
    echo
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
    echo -e "${C_DIM}Coletando logs do boot anterior (journalctl -b -1)...${C_RESET}" >&2

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

    journalctl -b -1 -n "$limite" --no-pager 2>/dev/null
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

    local regex='kernel panic|fatal exception|BUG: kernel|oom-killer|out of memory|watchdog: BUG:|soft lockup - CPU#|hard lockup - CPU#|NMI watchdog: Watchdog detected|thermal.*critical|critical temperature|Machine Check Exception|hardware error|I/O error|EXT[2-4]-fs error|xfs.*error|segfault|reboot: System reboot|Restarting system'

    local saida=""
    local max_lines=10000

    if ((${#arquivos_text[@]} > 0)); then
        saida+="$(grep -siE "$regex" "${arquivos_text[@]}" 2>/dev/null | tail -n $max_lines)"$'\n'
    fi

    if [[ "$MODE" == "FULL" && ${#arquivos_gz[@]} -gt 0 && -n "$(command -v zgrep 2>/dev/null)" ]]; then
        saida+="$(zgrep -siE "$regex" "${arquivos_gz[@]}" 2>/dev/null | tail -n $max_lines)"$'\n'
    fi

    echo "$saida" | sed '/^$/d' | tail -n 120
}

# =======================[ ANÁLISE ]=======================================

analisa_reinicio() {
    local journal="$1"
    local aux="$2"
    local journal_volatile="$3"

    local motivo_plain=""
    local motivo_color="$C_RESET"
    local trecho=""
    local origem=""

    local shutdown_limpo=0
    if [[ -n "$journal" ]] && grep -qiE 'systemd-shutdown\[|Shutting down\.|Reached target (Shutdown|Reboot|Power)' <<< "$journal"; then
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
            trecho="$(grep -iE "$regex" <<< "$LOGSOURCE" | head -n 10)"
            origem="$src"
        fi
    }

    local rx_panic='kernel panic|fatal exception|BUG: kernel'
    local rx_oom='oom-killer|out of memory'
    local rx_watchdog='watchdog: BUG:|soft lockup - CPU#|hard lockup - CPU#|NMI watchdog'
    local rx_thermal='thermal.*critical|critical temperature'
    local rx_hw='Machine Check Exception|hardware error'
    local rx_disk='I/O error|EXT[2-4]-fs error|xfs.*error'
    local rx_seg='segfault'
    local rx_powerbtn='systemd-logind\[.*\]: Power key pressed'
    local rx_update='unattended-upgrade|dpkg:.*linux-image|apt-get.*(dist-upgrade|full-upgrade)'
    local rx_reboot='reboot: System reboot|Restarting system'

    # Primeiro: tentar achar causa no journal do boot anterior (se existir)
    if [[ -n "$journal" ]]; then
        detecta_nos_logs "$journal" "$rx_panic"    "Kernel panic ou falha grave no kernel" "$C_RED"    "journal"
        detecta_nos_logs "$journal" "$rx_oom"      "Falta de memória (OOM)"               "$C_RED"    "journal"
        detecta_nos_logs "$journal" "$rx_watchdog" "Travamento de CPU (Watchdog)"         "$C_RED"    "journal"
        detecta_nos_logs "$journal" "$rx_thermal"  "Problema térmico (temperatura crítica)" "$C_RED"  "journal"
        detecta_nos_logs "$journal" "$rx_hw"       "Erro de hardware (MCE)"               "$C_RED"    "journal"
        detecta_nos_logs "$journal" "$rx_disk"     "Erro de disco/filesystem"             "$C_RED"    "journal"
        detecta_nos_logs "$journal" "$rx_seg"      "Segfault crítico em processo"         "$C_YELLOW" "journal"
        detecta_nos_logs "$journal" "$rx_powerbtn" "Botão de energia pressionado"         "$C_YELLOW" "journal"
        detecta_nos_logs "$journal" "$rx_update"   "Reboot possivelmente causado por atualização (apt/dpkg)" "$C_GREEN" "journal"
        detecta_nos_logs "$journal" "$rx_reboot"   "Reinício normal (sequência registrada)" "$C_GREEN" "journal"
    fi

    # Segundo: logs auxiliares de /var/log, mas APENAS se não achamos motivo antes.
    # E mesmo assim, são tratados como "causa provável" somente quando temos logs persistentes.
    if [[ -z "$motivo_plain" && -n "$aux" && "$MODE" == "FULL" && $journal_volatile -eq 0 ]]; then
        detecta_nos_logs "$aux" "$rx_panic"    "Kernel panic ou falha grave no kernel (logs auxiliares)" "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_oom"      "Falta de memória (OOM) (logs auxiliares)"               "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_watchdog" "Travamento de CPU (Watchdog) (logs auxiliares)"         "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_thermal"  "Problema térmico (logs auxiliares)"                     "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_hw"       "Erro de hardware (MCE) (logs auxiliares)"               "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_disk"     "Erro de disco/filesystem (logs auxiliares)"             "$C_RED"    "aux"
        detecta_nos_logs "$aux" "$rx_seg"      "Segfault crítico (logs auxiliares)"                     "$C_YELLOW" "aux"
        detecta_nos_logs "$aux" "$rx_reboot"   "Reinício normal (encontrado em logs auxiliares)"        "$C_GREEN"  "aux"
    fi

    echo -e "${C_BOLD}${C_GREEN}=========== ANÁLISE DO MOTIVO DO REINÍCIO ==========${C_RESET}"

    if [[ -n "$motivo_plain" ]]; then
        echo -e "Motivo detectado: ${motivo_color}${motivo_plain}${C_RESET}"
        if [[ "$origem" == "aux" ]]; then
            echo -e "${C_DIM}(Baseado em logs auxiliares de /var/log — podem incluir eventos mais antigos, não apenas o último reboot.)${C_RESET}"
        fi
        echo
        echo -e "${C_BOLD}Evidência:${C_RESET}"
        echo "$trecho"

    elif [[ $shutdown_limpo -eq 1 ]]; then
        echo -e "Reinício normal: sequência de desligamento detectada no journal (systemd-shutdown / Shutting down)."

    else
        if [[ $journal_volatile -eq 1 && -z "$journal" ]]; then
            echo -e "${C_YELLOW}Journald em modo volátil:${C_RESET} não há logs persistentes do boot anterior."
            if [[ "$MODE" == "FULL" && -n "$aux" ]]; then
                echo "Foram analisados logs auxiliares em /var/log, mas não foi possível determinar com segurança o motivo do último reboot."
            fi
            echo -e "Resultado: ${C_YELLOW}INCONCLUSIVO por falta de logs persistentes.${C_RESET}"
        else
            if [[ -z "$journal" && -z "$aux" ]]; then
                echo -e "${C_YELLOW}Inconclusivo:${C_RESET} não há logs suficientes no journal nem em /var/log."
            elif [[ -n "$journal" && $shutdown_limpo -eq 0 ]]; then
                echo -e "${C_RED}Reinício possivelmente abrupto:${C_RESET} não há sequência normal de shutdown no journal."
                echo "Provável travamento, reset físico ou queda de energia."
            else
                echo -e "${C_YELLOW}Inconclusivo:${C_RESET} não foi possível identificar um motivo claro com os logs disponíveis."
            fi
        fi
    fi

    echo -e "${C_BOLD}${C_GREEN}====================================================${C_RESET}"
    echo

    # Se não encontramos um motivo conclusivo, mas temos logs auxiliares,
    # mostramos apenas como INDÍCIOS (principalmente útil em journald volátil).
    if [[ -z "$motivo_plain" && -n "$aux" ]]; then
        echo "------ Indícios em logs históricos (/var/log) ------"
        echo "$aux"
        echo "(Atenção: estes eventos podem ser antigos e NÃO estão sendo usados como causa direta do último reboot.)"
        echo "===================================================="
        echo
    fi
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
        SAVE_FILE="/tmp/analise-reinicio-$ts.log"
        # Captura stdout e stderr
        exec > >(tee "$SAVE_FILE") 2>&1
        echo -e "${C_GREEN}Relatório será salvo em:${C_RESET} $SAVE_FILE"
        echo
    fi
}

# ============================[ MAIN ]=====================================

main() {
    parse_args "$@"
    init_colors
    requer_root
    habilita_save

    detecta_journal_volatile

    echo -e "${C_BOLD}${C_MAGENTA}Modo de operação:${C_RESET} $MODE"
    echo

    mostra_info_sistema
    mostra_boot_logs
    verifica_crash_dumps

    local journal aux
    journal="$(coleta_journal_boot_anterior)"
    aux="$(coleta_logs_aux)"

    analisa_reinicio "$journal" "$aux" "$JOURNAL_VOLATILE"
    mostra_trecho_journal "$journal" "$JOURNAL_VOLATILE"

    if [[ "$SAVE" -eq 1 ]]; then
        echo "Relatório salvo em: $SAVE_FILE"
    fi
}

main "$@"
