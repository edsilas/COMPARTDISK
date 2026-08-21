# Descrição dos Menus

**COMPARTDISK 1.4.6** · Desenvolvido por Edsilas

Mapa completo de todas as telas. Cada opção indica se **altera** o computador ou se
apenas **lê** informações.

Legenda: 🔵 **Leitura** (não muda nada) · 🟡 **Altera** o sistema · 🔴 **Altera e é irreversível**

---

## Menu Principal

| Tecla | Opção | Leva para |
|---|---|---|
| `1` | Reparo Geral Automático (One-Click Fix) | Executa direto |
| `2` | Aplicativos: Atualizar e Instalar (Winget) | Submenu Aplicativos |
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

### `2` — Aplicativos 🟡

Abre o submenu de aplicativos, com três capacidades independentes.

---

## Menu Aplicativos

| Tecla | Opção | Tipo |
|---|---|---|
| `1` | Verificar / preparar WinGet | 🟡 |
| `2` | Central de Aplicativos (pesquisar e instalar) | 🟡 |
| `3` | Atualizar aplicativos (WinGet) | 🟡 |
| `0` | Voltar | — |

A ordem segue o uso real: primeiro garantir o WinGet, depois instalar, por último
manter o que já está instalado.

**`1` Verificar / preparar WinGet** — diagnostica o gerenciador de pacotes do Windows
e, quando ele não está disponível, tenta prepará-lo por métodos oficiais. É o ponto de
partida quando aparece o aviso de WinGet indisponível.

**`2` Central de Aplicativos** — pesquisa **qualquer** aplicativo publicado na fonte
oficial do WinGet pelo nome e instala em poucos passos, sem exigir que você conheça
comandos ou identificadores de pacote. É o caminho de instalação do COMPARTDISK.

**`3` Atualizar aplicativos** — atualiza todos os programas instalados que o
gerenciador de pacotes do Windows conhece. É exatamente a rotina que antes ficava na
tecla `2` do menu principal, sem qualquer alteração de comportamento. Requer
internet. Programas em uso podem falhar — feche o que puder antes.

> A instalação a partir do **catálogo de suporte técnico** deixou de ser opção do
> menu: a Central de Aplicativos passou a ser o caminho único de instalação, e manter
> as duas era oferecer a mesma capacidade duas vezes. O catálogo continua em
> `Modules/Apps.ps1` para automação — `-Action Install`, `-Action InstallCategory`,
> `-Action InstallAll` e `-Action List` — e está descrito em
> [Funcionalidades](FUNCIONALIDADES.md).

### `1` — Verificar / preparar WinGet 🟡

Diagnostica o ambiente do WinGet e, quando ele não está disponível, tenta prepará-lo
**por métodos oficiais do Windows**. A tela mostra a ficha do diagnóstico — sistema,
build, arquitetura, App Installer, versão, fonte, Microsoft Store e política — e o
estado apurado: *disponível*, *desatualizado*, *não funcional*, *ausente*, *bloqueado
por política* ou *não suportado*.

O que a preparação faz, nesta ordem:

1. **Reparo local, sem baixar nada** — registra novamente o pacote do App Installer
   que já está na máquina. Resolve o caso mais comum, em que o `winget` some porque o
   registro do pacote se perdeu no perfil.
2. **Microsoft Store** — abre a página oficial do App Installer para você concluir a
   instalação. Depende da sua ação na janela da Store.

Depois de agir, o resultado é **validado de verdade**: existência do `winget.exe`,
`--version`, `--info`, fontes e uma consulta de teste. Só então a tela informa que o
WinGet está pronto e oferece voltar direto para os aplicativos.

### `2` — Central de Aplicativos 🟡

Pesquisa por nome e instalação em poucos passos, para quem não conhece o `winget`.
É a ação `Central` do módulo `Apps.ps1` — a mesma rotina de instalação e as mesmas
verificações do catálogo interno.

A tela pede **uma** coisa: o nome do aplicativo. Não é preciso acertar o nome exato —
a pesquisa ignora maiúsculas, acentos, espaços e hífens, entende abreviações e
apelidos e tolera erro de digitação:

| Você digita | A Central encontra |
|---|---|
| `chrome`, `chr`, `crome`, `google chrome` | Google Chrome |
| `7zip`, `7 zip` | 7-Zip |
| `vscode`, `vs code`, `code`, `visual code` | Visual Studio Code |
| `vlc`, `videolan` | VLC media player |

Os resultados **não** são a saída bruta do `winget search`: eles são classificados por
relevância. O **nome do aplicativo** pesa mais que o identificador e o editor; palavra
completa vale mais que pedaço de palavra; quem atende **todas** as palavras do termo
vem antes de quem atende uma só; e correspondência aproximada nunca supera
correspondência direta. Empates são desfeitos pela ordem em que a própria fonte
oficial devolveu os resultados.

Variações do mesmo pacote (`Google.Chrome` e `Google.Chrome.Beta`, `Mozilla.Firefox` e
`Mozilla.Firefox.ESR`) não ocupam várias das primeiras posições: a melhor de cada
família mantém o lugar e as irmãs recuam — sem sair da lista.

Muitos programas publicam **uma variante por idioma** (`Mozilla.Firefox.af`,
`Mozilla.Firefox.pt-BR`, …). A preferência do COMPARTDISK é **pt-BR › pacote base ›
português (pt / pt-PT) › en-US › demais localidades**, e o recuo cresce a cada tradução
seguinte, de modo que dezenas delas não tomem a primeira página. Nenhuma é removida.

O pacote publicado **com o nome em outra escrita** e sem localidade no identificador
(`Lenovo.LenovoVoice`, exibido em chinês) pesa como as demais localidades: continua na
lista, em *mais resultados relacionados*, sem tomar a frente de um resultado
equivalente em pt-BR ou en-US. O nome é exibido **exatamente** como o WinGet o
devolveu — o COMPARTDISK classifica, nunca traduz nem transcreve.

A localidade vem só de dado objetivo do resultado — o **segmento final do identificador
publicado**. **Editor não indica idioma** (`Mozilla` não torna um pacote pt-BR) e
**nome exibido também não**: `Mozilla Firefox (en-US)` é o rótulo do pacote *base*
`Mozilla.Firefox`, e não a variante `en-US`, que tem identificador próprio. Do mesmo
modo, `Mozilla.Firefox.ESR` e `Mozilla.Firefox.MSIX` são **outras edições** do mesmo
aplicativo, nunca idiomas. E o nome exibido é sempre o que o WinGet devolveu: o
COMPARTDISK ordena por idioma, nunca traduz nome de aplicativo.

A tela separa **Melhores resultados** de **Mais resultados relacionados**. Em
*melhores* ficam as correspondências diretas sem ressalva; em *relacionados*, canais
secundários (`Beta`, `Dev`, `Nightly`, `Insiders`) e pacotes de terceiros quando
existe um do próprio editor procurado. **Nada é escondido**: a numeração é contínua e
todo resultado válido do WinGet continua na tela.

Aparecem até oito por vez. Os **números são dos aplicativos**; a navegação tem tecla
fixa: `P` faz uma nova pesquisa e `V` volta — maiúscula ou minúscula, sempre no mesmo
lugar, **em todas as telas da Central**: com resultados, sem resultados, com o termo
em branco ou na pausa depois de instalar. Quando o WinGet devolve mais que isso — uma
pesquisa por `g`, por exemplo —, a tela informa quantos foram encontrados e sugere
refinar o termo.

Termos genéricos trazem o que a maioria das pessoas procura: `office`, `word` ou
`planilha` colocam Microsoft 365, LibreOffice e ONLYOFFICE na frente dos complementos
e utilitários de nome parecido; `navegador` e `browser` trazem os navegadores.

Uma pesquisa por `google` traz primeiro os pacotes cujo **editor publicado é o próprio
`Google`** e depois os de terceiros, como `arjun-g.google-meet-desktop`. Esse é o único
vínculo que os dados do WinGet permitem afirmar — o editor que consta no identificador
publicado. O COMPARTDISK **não** deduz oficialidade a partir do nome do programa e não
remove pacote de terceiro: apenas não o coloca no lugar do oficial.

Tecle Enter sem digitar nada e a tela pede o nome, oferecendo `P` para pesquisar de
novo e `V` para voltar — as mesmas teclas da tela de resultados e da tela de "nenhum
aplicativo encontrado".

Escolhido um resultado, a tela mostra aplicativo, editor, pacote e fonte, verifica se
ele **já está instalado** — e, se estiver, diz isso e não instala nada, porque
atualizar continua sendo a opção `3`. Só depois da confirmação `[1]` a instalação
acontece, sempre pelo **identificador exato** confirmado na fonte oficial, e o estado
final é conferido consultando o sistema.

A única coisa digitada em toda a Central é o nome procurado. Ele é higienizado antes
de qualquer uso, viaja entre aspas como valor da consulta e **nunca** vira comando; o
identificador instalado é sempre o que o WinGet devolveu, nunca o texto digitado.

Sem PowerShell, o Launcher aplica a rotina Batch equivalente, com o mesmo fluxo. Ali
os apelidos mais comuns continuam sendo traduzidos, mas não há tolerância a erro de
digitação por semelhança nem classificação por relevância — a limitação é declarada
no próprio código.

Quando o Windows é antigo demais ou uma política corporativa bloqueia o App
Installer, a opção **não tenta forçar nada**: informa o motivo e encerra sem alterar
política alguma.

> Sem PowerShell, a rotina Batch equivalente diagnostica e abre a página da Store,
> mas não consegue registrar o pacote — e diz isso claramente, em vez de fingir que
> reparou.

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
