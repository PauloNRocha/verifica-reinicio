#!/usr/bin/env bash
# Cenários sintéticos com hostnames, sensores e identificadores fictícios. Não consulta journal/IPMI real nem carrega módulos.
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../verifica-reinicio.sh
source "$root/verifica-reinicio.sh"
init_colors
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT
checks=0
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf 'FALHOU: %s (esperado %s, recebido %s)\n' "$3" "$2" "$1" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
assert_has() {
    if ! grep -Fq -- "$2" <<< "$1"; then
        printf 'FALHOU: %s\n' "$3" >&2
        exit 1
    fi
    checks=$((checks + 1))
}
analyze() {
    EXIT_CODE=0
    analisa_reinicio "$1" "$2" "$3" "$4" > "$work/result"
    result="$(cat "$work/result")"
}
end='2026-02-04T12:21:20.500000-03:00'
log="$end host-exemplo pvedaemon[2062]: successful auth"
acpi='2026-02-04T12:21:20.400000-03:00 host-exemplo systemd-logind[800]: Power key pressed short'
shutdown="$end host-exemplo systemd-shutdown[1]: Powering off."
assert_eq "$(extrai_shutdown_ts "$shutdown")" "$end" 'timestamp sem hostname e com microssegundos'
analyze "$log" '' '' ''
assert_eq "$EXIT_CODE" 2 'abrupto sem causa continua inconclusivo'
assert_has "$result" 'Reinício possivelmente abrupto' 'restaura sinal observado na 1.2.4'
assert_has "$result" 'Causa não determinada.' 'abrupto não confirma energia'
# A mensagem principal deve se destacar no terminal e continuar limpa em pipes.
C_RED=$'\e[31m'
C_YELLOW=$'\e[33m'
C_BOLD=$'\e[1m'
C_RESET=$'\e[0m'
analyze "$log" '' '' ''
assert_has "$result" $'\e[1m\e[31mReinício possivelmente abrupto:' 'alerta vermelho no terminal'
assert_has "$result" $'\e[1m\e[33mCausa não determinada.' 'incerteza amarela no terminal'
init_colors
analyze "$log" '' '' ''
if [[ "$result" == *$'\e['* ]]; then
    echo 'FALHOU: ANSI em saída sem TTY' >&2
    exit 1
fi
checks=$((checks + 1))
analyze '' '' '' ''
assert_eq "$EXIT_CODE" 2 'sem registros'
if grep -Fq 'Reinício possivelmente abrupto' <<< "$result"; then
    echo 'FALHOU: não há base para inferir abrupto sem journal' >&2
    exit 1
fi
checks=$((checks + 1))
analyze "$log" '' 'Dec 29 kernel: Kernel panic - old' ''
assert_eq "$EXIT_CODE" 2 'panic histórico não determina reboot'
assert_has "$result" 'Indícios históricos' 'histórico identificado'
analyze "$log" '' '' '0004 | 02/04/2026 | 12:21:00 | Power Supply #0x01 | Power Supply AC lost | Deasserted'
assert_eq "$EXIT_CODE" 2 'recuperação IPMI não é perda ativa'
MODE=FULL
IPMI_CLOCK_OK=0
IPMI_SEL_LIST='0006 | 02/04/2026 | 11:00:00 -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
analyze "$log" '' '' ''
assert_eq "$EXIT_CODE" 2 'divergência BMC não transforma indício em causa'
assert_has "$result" 'Reinício possivelmente abrupto' 'abrupto mantém destaque no FULL'
assert_has "$result" 'Indício elétrico:' 'SEL com relógio divergente é indício'
C_YELLOW=$'\e[33m'
C_BOLD=$'\e[1m'
C_RESET=$'\e[0m'
analyze "$log" '' '' ''
assert_has "$result" $'\e[1m\e[33mIndício elétrico:' 'indício destacado sem apresentar como causa'
init_colors
IPMI_SEL_LIST='0007 | 02/04/2026 | 11:00:00 -03 | Power Supply #0x01 | Power Supply AC lost | Deasserted'
analyze "$log" '' '' ''
if grep -Fq 'Indício elétrico:' <<< "$result"; then
    echo 'FALHOU: apenas Deasserted não estabelece perda AC' >&2
    exit 1
fi
checks=$((checks + 1))
IPMI_SEL_LIST=''
MODE=FAST
analyze "$log" '' '' '0004 | 02/04/2026 | 12:21:00 | Power Supply #0x01 | Fully Redundant | Asserted'
assert_eq "$EXIT_CODE" 2 'redundância normal não é falha'
sel='0003 | 02/04/2026 | 12:28:24 PM -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
analyze "$acpi" '' '' "$sel"
assert_eq "$EXIT_CODE" 0 'energia correlacionada com ACPI'
assert_has "$result" 'Causa provável: Perda/instabilidade' 'classificação elétrica'
assert_has "$result" 'Sequência ACPI associada' 'preserva evidência ACPI'
analyze "$acpi" '' '' ''
assert_eq "$EXIT_CODE" 0 'mecanismo ACPI registrado'
analyze "$shutdown" '' '' ''
assert_eq "$EXIT_CODE" 0 'sequência final registrada'
for msg in 'NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.' 'Out of memory: Killed process 12 (java)' 'Memory cgroup out of memory' 'BUG: soft lockup - CPU#1' 'segfault at 0' 'Oops: 0000' 'hung_task: blocked'; do
    analyze "$log" "$end host-exemplo kernel: $msg" '' ''
    assert_eq "$EXIT_CODE" 2 "evento isolado: $msg"
done
analyze "$log" "$end host-exemplo kernel: Kernel panic - not syncing" '' ''
assert_eq "$EXIT_CODE" 0 'panic explícito'
for msg in 'Started unattended-upgrades.service - Unattended Upgrades Shutdown.' 'Started apcupsd.service.' 'Power Supply fully redundant'; do
    analyze "$end host-exemplo systemd[1]: $msg" '' '' ''
    assert_eq "$EXIT_CODE" 2 "mensagem normal: $msg"
done
analyze "$shutdown"$'\n'"$end host-exemplo systemd[1]: Started unattended-upgrades.service - Unattended Upgrades Shutdown." '' '' ''
if grep -qi 'causado por atualização' <<< "$result"; then exit 1; fi
checks=$((checks + 1))
IPMI_CLOCK_OK=1
CURRENT_BOOT_EPOCH="$(date -d '2026-02-04T12:29:45-03:00' +%s)"
near="$(filtra_ipmi_proximo "$end" "$sel")"
assert_eq "$near" "$sel" 'caso host-exemplo: último log 12:21 e SEL 12:28'
old='0001 | 02/03/2026 | 09:00:16 PM -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
after='0005 | 02/04/2026 | 12:30:00 PM -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo "$end" "$old"$'\n'"$after")" '' 'exclui eventos antigos e posteriores ao boot'
IPMI_CLOCK_OK=0
assert_eq "$(filtra_ipmi_proximo "$end" "$sel")" '' 'relógio não validado impede correlação'
# Grande volume de evidências não deve causar SIGPIPE.
large="$(awk 'BEGIN {for(i=0;i<20000;i++) print "2026-02-04T12:21:20-03:00 host-exemplo kernel: Kernel panic - not syncing"}')"
analyze "$log" "$large" '' ''
assert_eq "$EXIT_CODE" 0 'muitas evidências não interrompem análise'
# Coleta simulada: horário fracionário precisa chegar intacto a --until.
BOOT_END_EPOCH='1770218480.500000'
BOOT_END_TS="$end"
PREVIOUS_BOOT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# Mock chamado indiretamente por timeout.
# shellcheck disable=SC2329
journalctl() { printf '%s\n' "$*" > "$work/args"; printf '%s\n' "$log"; }
timeout() { shift 3; "$@"; }
coleta_journal_boot_anterior > "$work/journal"
assert_has "$(cat "$work/args")" '--until @1770218480.500000' 'preserva fração no limite superior'
assert_has "$(cat "$work/args")" '--since @1770216680' 'janela de 30 minutos'
assert_has "$(cat "$work/args")" '-n 1500' 'limite FAST'
MODE=FULL
coleta_journal_kernel_boot_anterior > "$work/journal"
assert_has "$(cat "$work/args")" '-k' 'coleta kernel separada'
assert_has "$(cat "$work/args")" '-n 8000' 'limite FULL'
unset -f journalctl timeout
# CLI e códigos sem executar coleta real.
status=0
bash "$root/verifica-reinicio.sh" --help > /dev/null || status=$?
assert_eq "$status" 0 'ajuda'
status=0
bash "$root/verifica-reinicio.sh" --invalido > /dev/null 2>&1 || status=$?
assert_eq "$status" 1 'argumento inválido'
# main isolada: mocks impedem acesso a logs, hardware e modprobe.
(
    requer_root() { :; }
    prepara_journal() { :; }
    mostra_info_sistema() { :; }
    mostra_boot_overview() { :; }
    coleta_journal_boot_anterior() { printf '%s\n' "$log"; }
    coleta_journal_kernel_boot_anterior() { :; }
    coleta_logs_aux() { echo 'FAST consultou logs auxiliares' >&2; exit 99; }
    coleta_ipmi() { echo 'FAST consultou IPMI' >&2; exit 99; }
    main --fast
) > "$work/fast" 2>&1 && status=0 || status=$?
assert_eq "$status" 2 'FAST isolado termina inconclusivo sem consultas FULL'
# A causa deve aparecer antes do histórico de boots, que pode ocupar várias telas.
(
    requer_root() { :; }
    prepara_journal() { :; }
    mostra_info_sistema() { :; }
    mostra_boot_overview() { echo 'HISTORICO_DE_BOOTS'; }
    verifica_crash_dumps() { :; }
    coleta_journal_boot_anterior() { printf '%s\n' "$log"; }
    coleta_journal_kernel_boot_anterior() { :; }
    coleta_logs_aux() { :; }
    coleta_ipmi() { :; }
    main --full
) > "$work/ordem" 2>&1 && status=0 || status=$?
assert_eq "$status" 2 'ordem de saída mantém código inconclusivo'
if ! awk '/Reinício possivelmente abrupto:/ {resultado=NR} /HISTORICO_DE_BOOTS/ {historico=NR} END {exit !(resultado > 0 && historico > resultado)}' "$work/ordem"; then
    echo 'FALHOU: histórico de boots apareceu antes do resultado' >&2
    exit 1
fi
checks=$((checks + 1))
# Salvamento real apenas de texto sintético, em arquivo privado temporário.
(
    SAVE=1
    HOSTNAME_SAFE=teste-regressao
    trap finaliza EXIT
    habilita_save
    printf '%s\n' "$SAVE_FILE" > "$work/path"
    printf 'relatorio sintetico\n'
    exit 2
) > "$work/save" 2>&1 && status=0 || status=$?
assert_eq "$status" 2 'salvar preserva código inconclusivo'
report="$(cat "$work/path")"
assert_eq "$(stat -c %a "$report")" 600 'permissão privada'
assert_has "$(cat "$report")" 'relatorio sintetico' 'gravação finalizada'
rm -- "$report"
(
    SAVE=1
    mktemp() { return 1; }
    habilita_save
) > /dev/null 2>&1 && status=0 || status=$?
assert_eq "$status" 3 'falha mktemp sem fallback inseguro'
(
    SAVE=1
    tee() { cat > /dev/null; return 1; }
    trap finaliza EXIT
    habilita_save
    printf '%s\n' "$SAVE_FILE" > "$work/path"
    echo 'teste de falha'
) > "$work/tee" 2>&1 && status=0 || status=$?
assert_eq "$status" 3 'falha tee é erro de execução'
rm -- "$(cat "$work/path")"
# Conversões SEL: meia-noite, meio-dia, offset e formato inválido.
assert_eq "$(epoch_ipmi '02/04/2026 12:00:00 AM -03')" "$(date -d '2026-02-04T00:00:00-03:00' +%s)" 'SEL meia-noite'
assert_eq "$(epoch_ipmi '02/04/2026 12:00:00 PM -03')" "$(date -d '2026-02-04T12:00:00-03:00' +%s)" 'SEL meio-dia'
assert_eq "$(epoch_ipmi '02/04/2026 15:28:24 +0000')" "$(date -d '2026-02-04T15:28:24Z' +%s)" 'SEL 24 horas UTC'
assert_eq "$(epoch_ipmi 'Pre-Init Time-stamp')" '' 'SEL sem data'
assert_eq "$(epoch_ipmi '02/31/2026 12:00:00 PM -03')" '' 'SEL data inválida'
IPMI_CLOCK_OK=1
CURRENT_BOOT_EPOCH="$(date -d '2026-02-05T12:29:45-03:00' +%s)"
assert_eq "$(filtra_ipmi_proximo "$end" "$sel")" '' 'intervalo grande exige investigação manual'
CURRENT_BOOT_EPOCH="$(date -d '2026-02-04T12:29:45-03:00' +%s)"
# Prepara journal com listagem sintética, mantendo o boot atual real apenas como âncora.
mock_current_id="$(tr -d '-' < /proc/sys/kernel/random/boot_id)"
mock_current_id="${mock_current_id//$'\n'/}"
timeout() { shift 3; "$@"; }
# shellcheck disable=SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    else
        printf '%s\n' '1770218480.500000 host-exemplo kernel: last record'
    fi
}
prepara_journal
assert_eq "$BOOT_END_EPOCH" '1770218480.500000' 'referência obtida com microssegundos'
assert_eq "$PREVIOUS_BOOT_ID" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 'fixa ID do boot'
# shellcheck disable=SC2329
journalctl() {
    if [[ "$1" == '--list-boots' ]]; then
        printf '%s\n' '-1 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dates unused' "0 $mock_current_id dates unused"
    else
        printf '%s\n' 'invalid timestamp'
    fi
}
prepara_journal
assert_eq "$BOOT_END_EPOCH" '' 'referência inválida não libera consulta sem janela'
assert_eq "$(coleta_journal_boot_anterior)" '' 'não coleta sem referência válida'
unset -f journalctl timeout
# Ausência de journalctl: não confundir com evidência de falha elétrica.
(
    # Mock consultado indiretamente pela coleta.
    # shellcheck disable=SC2329
    command() {
        if [[ "$*" == '-v journalctl' ]]; then return 1; fi
        builtin command "$@"
    }
    BOOT_END_EPOCH=''
    prepara_journal
    [[ -z "$BOOT_END_EPOCH" ]]
) > "$work/missing" 2>&1
assert_has "$(cat "$work/missing")" 'journalctl não encontrado' 'degrada sem journalctl'
# Falha no journal é distinguida de ausência de evidências.
BOOT_END_EPOCH='1770218480.500000'
timeout() { return 124; }
coleta_journal_boot_anterior > /dev/null 2>&1 && status=0 || status=$?
assert_eq "$status" 3 'timeout journal retorna erro'
unset -f timeout
EXIT_CODE=3
analisa_reinicio "$shutdown" '' '' '' > /dev/null
assert_eq "$EXIT_CODE" 3 'evidência não oculta erro de coleta'
# FULL sem journal ainda fornece indícios históricos, mas não confirma causa.
(
    requer_root() { :; }
    prepara_journal() { :; }
    mostra_info_sistema() { :; }
    mostra_boot_overview() { :; }
    verifica_crash_dumps() { :; }
    coleta_journal_boot_anterior() { :; }
    coleta_journal_kernel_boot_anterior() { :; }
    coleta_logs_aux() { echo 'old kernel: Kernel panic'; }
    coleta_ipmi() { :; }
    EXIT_CODE=0
    main --full
) > "$work/full" 2>&1 && status=0 || status=$?
assert_eq "$status" 2 'FULL só histórico permanece inconclusivo'
assert_has "$(cat "$work/full")" 'old kernel: Kernel panic' 'FULL mantém histórico visível'
# Falhas opcionais do BMC: simula timeout e relógio divergente.

# Apenas presença do comando: timeout simulado fornece o resultado.
# shellcheck disable=SC2329
ipmitool() { :; }
# shellcheck disable=SC2329
modprobe() { :; }
timeout() {
    case "$*" in
        *'sel time get') echo '02/04/2026 12:45:39 PM -03' ;;
        *'sel list last 50') printf '%s\n' "$sel"; return 124 ;;
    esac
}
coleta_ipmi 2> "$work/ipmi"
assert_eq "$IPMI_AVAILABLE" 0 'timeout SEL não indica disponibilidade'
assert_eq "$IPMI_SEL_LIST" '' 'descarta SEL parcial'
timeout() {
    case "$*" in
        *'sel time get') echo '01/01/2000 12:00:00 AM -03' ;;
        *'sel list last 50') printf '%s\n' "$sel" ;;
    esac
}
coleta_ipmi 2> "$work/ipmi"
assert_eq "$IPMI_AVAILABLE" 1 'SEL acessível'
assert_eq "$IPMI_CLOCK_OK" 0 'relógio divergente'
assert_eq "$IPMI_SEL_NEAR" '' 'não classifica SEL com relógio divergente'
unset -f ipmitool modprobe timeout
# Regressão do FULL no Ubuntu: mensagens normais não são indícios.
noise="$(cat <<'LOG'
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: Adding input device Power Button (/dev/input/event1)
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: Power Button: Applying InputClass libinput keyboard catchall
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: Power Button: always reports core events
2026-09-21T08:54:35-03:00 host-exemplo gdm-x-session[2269]: event1 - Power Button: device removed
2026-09-18T12:32:09-03:00 host-exemplo systemd[1]: anacron.service skipped (ConditionACPower=true).
2026-09-18T12:46:25-03:00 host-exemplo systemd[1]: Stopping cups-browsed.service - Make remote CUPS printers available locally...
2026-09-19T09:47:48-03:00 host-exemplo kernel: ftrace: allocated 228 pages with 4 groups
2026-09-19T09:47:48-03:00 host-exemplo kernel: CPU0: Thermal monitoring enabled (TM1)
2026-09-19T09:47:48-03:00 host-exemplo kernel: thermal_sys: Registered thermal governor power_allocator
2026-09-19T09:47:48-03:00 host-exemplo kernel: ACPI: New power resource
2026-09-19T09:47:48-03:00 host-exemplo kernel: thermal thermal_zone10: failed to read out thermal zone (-61)
2026-09-19T09:47:48-03:00 host-exemplo systemd[1]: Reached target nss-lookup.target - Host and Network Name Lookups.
2026-09-19T09:47:48-03:00 host-exemplo systemd[1]: Starting thermald.service - Thermal Daemon Service...
2026-09-19T09:47:48-03:00 host-exemplo systemd[1]: Starting power-profiles-daemon.service - Power Profiles daemon...
2026-09-19T09:47:48-03:00 host-exemplo kernel: NMI watchdog: Enabled. Permanently consumes one hw-PMU counter.
LOG
)"
assert_eq "$(filtra_indicios "$noise")" '' 'ignora mensagens normais fornecidas pelo usuário'
for event in 'Kernel panic - not syncing' 'BUG: soft lockup - CPU#1 stuck for 26s' 'NMI watchdog: Watchdog detected hard LOCKUP' 'Out of memory: Killed process 123 (java)' 'critical temperature reached (100 C), shutting down' 'I/O error, dev sda' 'Hardware Error: Machine Check Exception' 'segfault at 0' 'Power failure detected' 'Power Supply AC lost' 'UPS on battery'; do
    event_line="2026-09-21T08:54:35-03:00 host-exemplo kernel: $event"
    assert_eq "$(filtra_indicios "$noise"$'\n'"$event_line")" "$event_line" "preserva evento: $event"
done
assert_eq "$(filtra_indicios "$acpi")" "$acpi" 'preserva logind Power key realmente pressionada'
EXIT_CODE=0
analyze "$log" "$noise" '' ''
assert_eq "$EXIT_CODE" 2 'ruído térmico não determina causa'
if grep -Fq 'Indícios do kernel' <<< "$result"; then
    echo 'FALHOU: cabeçalho de indícios para kernel normal' >&2
    exit 1
fi
checks=$((checks + 1))
mkdir "$work/logs"
printf '%s\n' "$noise" > "$work/logs/syslog"
: > "$work/logs/kern.log"
assert_eq "$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")" '' 'sem cabeçalhos vazios nos logs históricos'
assert_has "$(cat "$work/aux-warnings")" 'Nenhum evento relevante encontrado' 'resumo quando amostras não contêm eventos'
printf '%s\n' "$noise" "$acpi" > "$work/logs/syslog"
history="$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")"
assert_has "$history" "$acpi" 'coleta preserva ocorrência histórica relevante'
if grep -Eq 'kern.log|Power Button|CUPS|groups|Thermal monitoring' <<< "$history"; then
    echo 'FALHOU: ruído ou cabeçalho vazio na coleta histórica' >&2
    exit 1
fi
checks=$((checks + 1))
if command -v gzip >/dev/null 2>&1; then
    printf '%s\n' "$noise" | gzip > "$work/logs/syslog.1.gz"
    history="$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")"
    if grep -Fq 'syslog.1.gz' <<< "$history"; then exit 1; fi
    checks=$((checks + 1))
    printf '%s\n' "$noise" "$acpi" | gzip > "$work/logs/syslog.1.gz"
    history="$(coleta_logs_aux "$work/logs" 2> "$work/aux-warnings")"
    assert_has "$history" 'syslog.1.gz' 'arquivo comprimido aparece se contém ocorrência'
fi
touchpad='2026-09-21T09:36:11.709643-03:00 host-exemplo /usr/libexec/gdm-x-session[4769]: (EE) event4 - Example Touchpad: kernel bug: Touch jump detected and discarded.'
assert_eq "$(filtra_indicios "$touchpad")" '' 'libinput não é BUG emitido pelo kernel'
kernel_bug='2026-09-21T09:36:11-03:00 host-exemplo kernel: BUG: unable to handle page fault'
assert_eq "$(filtra_indicios "$kernel_bug")" "$kernel_bug" 'mantém BUG emitido pelo kernel'
# Regressão host-exemplo: SEL MM/DD/YY e diferença de relógio explícita.
assert_eq "$(epoch_ipmi '01/15/26 09:00:00 -03')" "$(date -d '2026-01-15T09:00:00-03:00' +%s)" 'ano curto e offset'
assert_eq "$(epoch_ipmi '01/15/26 09:00:00 AM -03')" "$(epoch_ipmi '01/15/2026 09:00:00 AM -03')" 'ano curto AM/PM'
assert_eq "$(epoch_ipmi '01/01/68 00:00:00 UTC')" "$(date -d '2068-01-01T00:00:00Z' +%s)" 'limite superior século 2000'
assert_eq "$(epoch_ipmi '01/01/69 00:00:00 UTC')" "$(date -d '1969-01-01T00:00:00Z' +%s)" 'limite inferior século 1900'
assert_eq "$(epoch_ipmi '02/30/26 09:00:00 -03')" '' 'ano curto não aceita data inválida'
assert_eq "$(epoch_ipmi '01/15/026 09:00:00 -03')" '' 'rejeita ano de três dígitos'
host_epoch="$(date -d '2026-01-15T12:00:00-03:00' +%s)"
valida_relogio_ipmi '01/15/26 09:00:00 -03' "$host_epoch" 2> "$work/clock"
assert_eq "$IPMI_CLOCK_OK" 0 'três horas de atraso impedem correlação'
assert_eq "$IPMI_CLOCK_DELTA" 10800 'diferença em segundos'
assert_has "$(cat "$work/clock")" 'atrasado 10800 segundos' 'aviso de divergência, não de parse'
if grep -q 'sem fuso explícito' "$work/clock"; then exit 1; fi
checks=$((checks + 1))
valida_relogio_ipmi '01/15/26 12:00:00 -03' "$host_epoch" 2> "$work/clock"
assert_eq "$IPMI_CLOCK_OK" 1 'ano curto sincronizado permite correlação'
assert_eq "$IPMI_CLOCK_DELTA" 0 'relógios sincronizados'
valida_relogio_ipmi '01/15/26 15:00:00 -03' "$host_epoch" 2> "$work/clock"
assert_has "$(cat "$work/clock")" 'adiantado 10800 segundos' 'direção da diferença'
valida_relogio_ipmi 'data inválida' "$host_epoch" 2> "$work/clock"
assert_eq "$IPMI_CLOCK_DELTA" '' 'parse inválido não fabrica diferença'
assert_has "$(cat "$work/clock")" 'não interpretável' 'aviso específico de parse'
valida_relogio_ipmi '01/15/26 12:00:00' "$host_epoch" 2> "$work/clock"
assert_has "$(cat "$work/clock")" 'sem fuso explícito' 'aviso apenas se falta offset'
IPMI_CLOCK_OK=1
CURRENT_BOOT_EPOCH="$(date -d '2026-01-15T11:00:00-03:00' +%s)"
short_sel='0002 | 01/15/26 | 10:58:00 -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo '2026-01-15T10:55:00.500000-03:00' "$short_sel")" "$short_sel" 'correlação SEL ano curto'
old_sel='0001 | 01/15/26 | 09:30:00 -03 | Power Supply #0x01 | Power Supply AC lost | Asserted'
assert_eq "$(filtra_ipmi_proximo '2026-01-15T10:55:00.500000-03:00' "$old_sel")" '' 'evento sintético fora da janela não está na janela'
printf 'OK: %s verificações com dados sintéticos.\n' "$checks"
