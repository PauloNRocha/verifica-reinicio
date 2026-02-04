# 🔍 verifica-reinicio.sh  
Ferramenta avançada para diagnosticar o motivo do último reinício do sistema Linux.

**Versão:** 1.2.4 (2026-02-04)

Criado para administradores que precisam entender **o porquê** de um servidor reiniciar — seja por:
- Kernel Panic  
- OOM (Out of Memory)  
- Travamento de CPU (Watchdog)  
- Erros de disco  
- Problemas térmicos  
- Falha elétrica / reboot abrupto  
- Atualizações automáticas  
- Botão físico / ACPI  
- Ou quando simplesmente não há logs suficientes para determinar…

Esse script automatiza todo o processo de análise que normalmente exigiria diversos comandos manuais.

---

## ✨ Recursos principais

✔️ Analisa **journalctl do boot anterior**  
✔️ Exibe histórico de boots (`journalctl --list-boots`)  
✔️ Mostra linha do tempo com `who -b` e `uptime`  
✔️ Analisa **logs auxiliares** em `/var/log/*`  
✔️ Suporta leitura de logs compactados (`.gz`)  
✔️ Detecta quando o **journald é volátil** (logs perdidos no reboot)  
✔️ Identifica causas **com evidência completa**  
✔️ Diferencia “causa real” de “indícios antigos”  
✔️ Modo rápido (FAST) e modo profundo (FULL)  
✔️ Pode salvar relatório completo com `--save`  
✔️ IPMI SEL opcional no modo FULL (quando disponível)  
✔️ Funciona em: Debian, Ubuntu, RHEL, Rocky, AlmaLinux e até servidores **cPanel/WHM**

---

## 🛠️ Instalação

```bash
git clone https://github.com/PauloNRocha/verifica-reinicio
cd verifica-reinicio
chmod +x verifica-reinicio.sh
````

Ou baixe apenas o script:

```bash
wget https://raw.githubusercontent.com/PauloNRocha/verifica-reinicio/main/verifica-reinicio.sh
chmod +x verifica-reinicio.sh
```

---

## 🚀 Como usar

### Modo rápido (padrão)

Usa apenas o journal + padrões essenciais.

```bash
sudo ./verifica-reinicio.sh
```

### Modo profundo (FULL)

Analisa também `/var/log/*` e logs `.gz`.

```bash
sudo ./verifica-reinicio.sh --full
```

### Salvar relatório em arquivo

Gera `/tmp/analise-reinicio-HOST-AAAA-MM-DD_HH-MM-SS-XXXXXX.log`:
`HOST` é o hostname detectado. `XXXXXX` é um sufixo aleatório.

```bash
sudo ./verifica-reinicio.sh --save
```

### FULL + salvar

```bash
sudo ./verifica-reinicio.sh --full --save
```

### Ver versão do script

```bash
sudo ./verifica-reinicio.sh --version
```

---

## 🧠 Estrutura da análise

O script usa uma hierarquia para determinar a causa com segurança:

### 1️⃣ **Journalctl (boot anterior)**

Se existir → É a fonte mais confiável
Se indicar Kernel Panic, OOM, Watchdog… → causa confirmada

### 2️⃣ **Logs persistentes em `/var/log` (apenas no modo FULL)**

Usado quando:

* journalctl está ausente
* journald é volátil
* modo FULL está ativado

Nesses casos é considerado **indício**, e o script deixa claro quando não é possível afirmar a causa com 100% de certeza.

### 3️⃣ **Failsafe – Inconclusivo**

Se não houver logs suficientes → o script avisa com clareza
E sugere habilitar journald persistente se necessário.

---

## 🔌 IPMI (opcional)

Se o `ipmitool` estiver disponível, o modo FULL coleta o SEL e tenta correlacionar eventos próximos ao shutdown detectado no journal. Isso ajuda a identificar perda/instabilidade elétrica quando o journal indica apenas shutdown limpo.

## 🔧 Exemplos de resultados

### ✔️ Kernel Panic detectado

```
Motivo detectado: Kernel panic ou falha grave no kernel
Evidência:
kernel: Kernel panic - not syncing: fatal exception
```

### ✔️ Falta de memória (OOM)

```
Motivo detectado: Falta de memória (OOM)
Evidência:
kernel: Out of memory: Kill process 1234 (mysqld)
```

### ✔️ Travamento de CPU (Watchdog)

```
Motivo detectado: Travamento de CPU (Watchdog)
Evidência:
kernel: watchdog: BUG: soft lockup - CPU#7 stuck for 63s!
```

### ❗ Journald volátil — motivo indeterminado

```
Journald em modo volátil: não há logs persistentes do boot anterior.
Resultado: INCONCLUSIVO por falta de logs persistentes.
```

### ❗ Apenas indícios antigos (modo FULL)

```
------ Indícios em logs históricos (/var/log) ------
kernel: I/O error, dev sda, sector 1239821
(Atenção: estes eventos podem ser antigos e NÃO estão sendo usados como causa direta do último reboot.)
```

---

## 📦 Arquitetura suportada

* Debian 10, 11, 12
* Ubuntu 18.04 → 24.04
* Rocky / AlmaLinux / RHEL 8+
* Servidores cPanel/WHM
* Bare-metal, VMs, Proxmox, VMware, Hyper-V etc.

---

## 📁 Estrutura do Repositório

```
verifica-reinicio/
 ├── verifica-reinicio.sh
 ├── LICENSE
 └── README.md
```

---

## 📜 Licença

Este projeto é licenciado sob:

```
GPL-3.0-or-later
```

Isso significa:

* Você pode usar, copiar, modificar e distribuir.
* Mas deve **manter os créditos originais**.
* E qualquer versão modificada também deve ser distribuída sob GPL.

Texto completo: [https://www.gnu.org/licenses/gpl-3.0.txt](https://www.gnu.org/licenses/gpl-3.0.txt)

---

## 👤 Autor

**Paulo Rocha**
GitHub: [https://github.com/PauloNRocha](https://github.com/PauloNRocha)

Script criado por mim, com apoio do ChatGPT (OpenAI) no refinamento e estruturação.

---

## 💬 Contribuições

Pull Requests são bem-vindos!

Se quiser melhorar detecções, regex, adicionar novos modos, ou integrar com Prometheus/Zabbix/Elastic — é só abrir uma issue.

---

## ⭐ Gostou?

Deixe uma estrela no repositório para ajudar outras pessoas a encontrarem a ferramenta!
