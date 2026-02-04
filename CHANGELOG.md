# Changelog

## 1.2.3 - 2026-02-04
- Usa o timestamp de fim do boot a partir de `journalctl --list-boots` para referência da causa.
- Ajusta a coleta do IPMI para `ipmitool sel list last 50` com fallback.
- Atualiza versão no README e no script.

## 1.2.2 - 2026-02-04
- Limita a heurística à janela próxima do fim do boot para evitar eventos antigos.
- Usa `mktemp` no arquivo de log e aplica `timeout` no IPMI.
- Corrige regex de reboot e parsing de data do IPMI.

## 1.2.1 - 2026-02-03
- Inclui hostname no relatório e no nome do arquivo.

## 1.2.0 - 2026-02-03
- Reestrutura o modo FAST/FULL e amplia a análise do journal.
- Adiciona heurísticas para energia, ACPI e falhas de kernel.

## 1.0.0 - 2025-12-04
- Primeira versão do script no repositório.
