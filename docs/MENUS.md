# Descrição dos Menus

**COMPARTDISK 1.3.1** · Desenvolvido por Edsilas

Mapa completo de todas as telas. Cada opção indica se **altera** o computador ou se
apenas **lê** informações.

Legenda: 🔵 **Leitura** (não muda nada) · 🟡 **Altera** o sistema · 🔴 **Altera e é irreversível**

---

## Menu Principal

| Tecla | Opção | Leva para |
|---|---|---|
| `1` | Reparo Geral Automático (One-Click Fix) | Executa direto |
| `2` | Atualizar Programas (Winget) | Executa direto |
| `3` | Rede, Internet e Conectividade | Submenu Rede |
| `4` | Otimização, Limpeza Profunda e Privacidade | Submenu Otimização |
| `5` | Reparo do Sistema, Windows Update e Explorer | Submenu Reparo |
| `6` | Contas, Permissões e Segurança | Submenu Segurança |
| `7` | Discos, Drivers e Auditoria de Hardware | Submenu Hardware |
| `8` | Diagnóstico Avançado e Relatórios | Submenu Diagnóstico |
| `9` | Ambiente de Execução e Capacidades | Tela Ambiente |
| `0` | Sair e Salvar Relatório | Encerra |

### `1` — Reparo Geral Automático 🟡

Executa em sequência, sem perguntar nada: limpeza profunda, reset de rede, reparo do
Windows Update, fila de impressão, reinício do Explorer, reparo profundo do sistema e
relatório final. De 20 a 60 minutos. **Reinicie ao terminar.**

### `2` — Atualizar Programas (Winget) 🟡

Atualiza todos os programas instalados que o gerenciador de pacotes do Windows
conhece. Requer internet. Programas em uso podem falhar — feche o que puder antes.

---

## Menu Rede

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Reset Completo (DNS, Winsock, TCP/IP, ARP, IPv6, Proxy) | 🟡 |
| `2` | Restaurar Arquivo Hosts | 🟡 |
| `3` | Restaurar Firewall | 🟡 |
| `4` | Diagnóstico de Adaptadores, DNS, DHCP, MTU e Rotas | 🔵 |
| `5` | Teste de Conectividade e Resolução de Nomes | 🔵 |
| `6` | Configuração de Proxy | 🔵 |
| `7` | Diagnóstico Wi-Fi | 🔵 |
| `0` | Voltar | — |

**`1` Reset Completo** — nove passos que devolvem a rede ao estado padrão. É a opção
que mais resolve problemas de internet. **Reinicie depois.**

**`2` Restaurar Arquivo Hosts** — o arquivo `hosts` pode ser usado para bloquear
sites; programas indesejados o alteram. Esta opção o devolve ao padrão, guardando
uma cópia do anterior.

**`3` Restaurar Firewall** — apaga todas as regras personalizadas e volta ao padrão.
Exporta as regras atuais antes. Programas que dependiam de regras próprias podem
precisar de nova autorização.

---

## Menu Otimização

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Limpeza Customizada (caches extensos, perfis, updates) | 🔴 |
| `2` | Desativar Telemetria | 🟡 |
| `3` | Aplicar Perfil Desempenho Máximo | 🟡 |
| `4` | Simular Limpeza | 🔵 |
| `5` | Limpeza de Navegadores | 🔴 |
| `6` | Análise de Desempenho | 🔵 |
| `7` | Restaurar Telemetria ao Padrão do Windows | 🟡 |
| `8` | Restaurar Plano de Energia Equilibrado | 🟡 |
| `9` | Desbloat do Windows — abre submenu próprio | 🟡 |

#### Submenu do Desbloat — `[4]` › `[9]`

| Tecla | Ação | Risco |
|:---:|---|:---:|
| `1` | Simular Desbloat — não altera nada | 🟢 |
| `2` | Desbloat Seguro | 🟡 |
| `3` | Desbloat Moderado | 🟠 |
| `4` | Desbloat Avançado | 🔴 |
| `5` | Remover Somente Aplicativos | 🟠 |
| `6` | Ajustar Serviços e Tarefas Agendadas | 🟡 |
| `7` | Privacidade e Ajustes Opcionais | 🟢 |
| `8` | Limpar Componentes Obsoletos (WinSxS) | 🟡 |
| `9` | Backup, Ponto de Restauração e Reverter | 🟢 |

#### Backup e reversão — `[4]` › `[9]` › `[9]`

| Tecla | Ação | Risco |
|:---:|---|:---:|
| `1` | Criar Ponto de Restauração Agora | 🟢 |
| `2` | Registrar Estado Atual (backup) | 🟢 |
| `3` | Simular Reversão | 🟢 |
| `4` | Reverter Alterações do Desbloat | 🟡 |
| `0` | Voltar | — |

**`4` Simular Limpeza** — comece por aqui. Mostra quanto espaço cada categoria
liberaria, **sem apagar nada**.

**`1` Limpeza Customizada** — pergunta se deve apagar também logs de eventos e
arquivos de falha. Responder **N** é o mais seguro: esses arquivos ajudam a
diagnosticar problemas depois.

**`5` Limpeza de Navegadores** — limpa cache de Edge, Chrome, Brave e Firefox.
Senhas e favoritos **não** são afetados. Feche os navegadores antes.

**`2` e `7`** — a telemetria pode ser desativada e restaurada. Toda alteração aqui
é reversível.

---

## Menu Reparo

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Reparo Profundo (DISM + SFC) | 🟡 |
| `2` | Destravar Windows Update | 🟡 |
| `3` | Destravar Fila de Impressão | 🟡 |
| `4` | Reiniciar Windows Explorer | 🟡 |
| `5` | Agendar Verificação de Disco (CHKDSK) | 🟡 |
| `6` | Status e Histórico do Windows Update | 🔵 |
| `7` | Procurar Atualizações Pendentes | 🔵 |
| `8` | Limpar Somente o Cache do Windows Update | 🟡 |
| `9` | Reconstruir Cache de Ícones e Miniaturas | 🟡 |
| `0` | Voltar | — |

**`1` Reparo Profundo** — verifica e repara os arquivos do Windows. De 15 a 45
minutos. É a opção certa para erros estranhos e inexplicáveis.

**`4` Reiniciar Explorer** — a barra de tarefas e os ícones desaparecem por alguns
segundos e voltam. É normal. Resolve barra de tarefas travada.

**`5` CHKDSK** — a verificação real acontece na próxima inicialização do Windows,
antes da tela de logon, e pode demorar bastante.

---

## Menu Segurança

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Resetar GPO Local | 🔴 |
| `2` | Gerenciar Contas Locais | 🔴 |
| `3` | Forçar Varredura Defender | 🟡 |
| `4` | Assumir Controle de Pasta/Arquivo | 🔴 |
| `5` | Postura de Segurança | 🔵 |
| `6` | Status do Defender e Antivírus Instalados | 🔵 |
| `7` | Varredura Completa do Defender | 🟡 |
| `8` | Exclusões e Histórico de Ameaças | 🔵 |
| `9` | Auditoria de Contas, Grupos e Falhas de Logon | 🔵 |
| `0` | Voltar | — |

> **Atenção.** Em computador de empresa, as opções `1`, `2` e `4` podem violar
> políticas da organização. Confirme com o setor de TI antes.

**`1` Resetar GPO Local** — apaga todas as diretivas de grupo locais. Faz backup
antes. Em máquina de empresa, isso pode desfazer configurações obrigatórias.

**`5` Postura de Segurança** — só leitura. Mostra Secure Boot, TPM, virtualização,
integridade de memória, UAC, SmartScreen e Windows Hello. Ótimo ponto de partida.

**`7` Varredura Completa** — pede confirmação. De 1 a 4 horas, com uso intenso do
processador.

---

## Menu Hardware

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Saúde Física dos Discos | 🔵 |
| `2` | Relatório de Bateria | 🔵 |
| `3` | Status BitLocker | 🔵 |
| `4` | Backup de Drivers | 🟡 |
| `5` | Auditoria de Sistema | 🔵 |
| `6` | Inventário Completo (CPU, RAM, GPU, monitores, USB, PCI, TPM) | 🔵 |
| `7` | Contadores de Confiabilidade e Desgaste dos Discos | 🔵 |
| `8` | Volumes, Espaço e Cópias de Sombra | 🔵 |
| `9` | Drivers com Problema e Sem Assinatura Digital | 🔵 |
| `0` | Voltar | — |

Este menu é quase todo de leitura — nada aqui muda o computador, exceto o backup de
drivers, que apenas cria arquivos.

**`1` Saúde Física dos Discos** — a leitura mais importante da ferramenta. Se
indicar problema, **faça backup imediatamente**.

**`2` Relatório de Bateria** — só faz sentido em notebook. Compara a capacidade
atual com a de fábrica, mostrando o desgaste real.

**`4` Backup de Drivers** — extrai todos os drivers instalados para uma pasta.
Faça isso **antes** de formatar.

---

## Menu Diagnóstico

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Auditoria Completa + Relatórios (TXT, CSV, JSON, HTML) | 🔵 |
| `2` | Auditoria Rápida | 🔵 |
| `3` | Consolidar Relatório da Sessão Atual | 🔵 |
| `4` | Eventos Críticos (7 dias) | 🔵 |
| `5` | Eventos Críticos (30 dias) | 🔵 |
| `6` | Inventário de Aplicativos Instalados | 🔵 |
| `7` | Licenciamento do Windows | 🔵 |
| `8` | Exportar Inventário de Drivers | 🔵 |
| `9` | Abrir o Último Relatório Gerado | 🔵 |
| `0` | Voltar | — |

**Menu inteiramente seguro.** Nada aqui altera o computador.

**`1` Auditoria Completa** — o retrato mais completo da máquina, em quatro formatos.
O HTML abre sozinho ao final. É o que enviar ao suporte técnico.

**`3` Consolidar Relatório** — junta tudo que foi feito nesta sessão em um relatório
único. Útil depois de executar vários reparos.

---

## Tela Ambiente de Execução

| Tecla | Opção |
|---|---|
| `1` | Detalhar capacidades via PowerShell |
| `2` | Reexecutar detecção de ambiente |
| `0` | Voltar |

Funciona como a tela "Sobre". Mostra produto, versão, autoria, motor em uso,
pasta dos módulos, identificador da sessão, arquivo de log e quais ferramentas do
Windows estão disponíveis (`1` = sim, `0` = não).

É a primeira tela a consultar quando algo não funciona: ela diz exatamente o que a
ferramenta encontrou no seu Windows.

---

[Voltar ao índice](../README.md) · Próximo: [Funcionalidades](FUNCIONALIDADES.md)
