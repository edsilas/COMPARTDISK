# Módulo de Desbloat

Referência completa do módulo que remove aplicativos pré-instalados, ajusta serviços
e tarefas agendadas, aplica ajustes de privacidade e compacta componentes obsoletos
do Windows.

**Menu:** `[4]` Otimização › `[9]` Desbloat do Windows
**Arquivo:** `Modules/Debloat.ps1`

---

## Índice

| Seção | Conteúdo |
|---|---|
| [1. O que é](#1-o-que-é) | Propósito e o que o distingue de uma limpeza comum |
| [2. Antes de começar](#2-antes-de-começar) | Simulação, ponto de restauração e o que preparar |
| [3. Níveis de limpeza](#3-níveis-de-limpeza) | Seguro, Moderado e Avançado em detalhe |
| [4. Submódulos](#4-submódulos) | Cada categoria, item por item |
| [5. Listas de proteção](#5-listas-de-proteção) | O que nunca é tocado, e por quê |
| [6. Reversão](#6-reversão) | Manifesto, ponto de restauração e o que não volta |
| [7. Uso avançado](#7-uso-avançado) | Parâmetros, filtros e execução seletiva |
| [8. Sem PowerShell](#8-sem-powershell) | O que a rotina Batch cobre |
| [9. Perguntas frequentes](#9-perguntas-frequentes) | Dúvidas comuns |

---

## 1. O que é

O Windows chega ao usuário com programas que ele não escolheu: jogos promocionais,
testes de antivírus, aplicativos de fabricante, sugestões no menu Iniciar. Somam-se
serviços e tarefas agendadas que rodam em segundo plano para funções que muita gente
nunca usa.

Este módulo remove esses itens de forma controlada, registrando o estado anterior de
cada alteração para permitir a volta.

**A diferença para uma limpeza de disco.** A limpeza (menu `[4]` › `[1]`) apaga
arquivos temporários e caches — coisas que o Windows recria sozinho. O desbloat
altera o que está instalado e o que roda. É uma operação de outra natureza, e por
isso tem simulação, níveis, proteções e reversão.

**O que ele não faz.** Não mexe em arquivos pessoais, não desinstala programas que
você mesmo instalou, não altera drivers e não toca em nada que o Windows precise para
funcionar.

### Números do catálogo

| | Aplicativos | Serviços | Tarefas | Privacidade | Ajustes | **Total** |
|---|---:|---:|---:|---:|---:|---:|
| Seguro | 109 | 6 | 8 | 16 | 6 | **145** |
| Moderado (acumulado) | 125 | 13 | 14 | 30 | 8 | **190** |
| Avançado (acumulado) | 129 | 15 | 14 | 30 | 9 | **197** |

Os níveis são cumulativos: o Moderado inclui tudo do Seguro, e o Avançado inclui tudo
dos dois anteriores.

Esses são os números do catálogo completo. **O total efetivo em uma máquina específica
é menor**, por dois motivos: 12 itens declaram a plataforma em que fazem efeito e são
ignorados fora dela, e itens cujo alvo não existe no sistema saem como `NaoInstalado`.
Um ajuste que só existe no Windows 11 não é aplicado no Windows 10 — seria inerte, e
relatar isso como sucesso seria falso.

---

## 2. Antes de começar

### Ordem recomendada

| Passo | Menu | Por quê |
|---|---|---|
| 1 | `[4]` › `[9]` › `[1]` | **Simule.** Lista item por item o que seria alterado, com o motivo. Não toca em nada. |
| 2 | `[4]` › `[9]` › `[9]` › `[2]` | **Registre o estado atual.** Cria um retrato de tudo que o catálogo alcança, antes de qualquer mudança. |
| 3 | `[4]` › `[9]` › `[2]` | **Execute o nível Seguro.** É o recomendado para a maioria dos casos. |
| 4 | — | **Reinicie.** Alterações de serviço e de componente só se consolidam depois. |

### Verificações que o módulo faz sozinho

Antes de qualquer alteração, o módulo confere e interrompe se algo estiver errado:

- Edição do Windows dentro do escopo suportado
- Privilégio administrativo presente
- Reinício pendente — avisa, mas não impede
- Módulos `Appx` e `ScheduledTasks` disponíveis — avisa e ignora a categoria correspondente
- Espaço livre no disco de sistema — avisa abaixo de 2 GB
- Ponto de restauração criado com sucesso — **interrompe** a rotina completa se falhar

### O que preparar

Nada de especial para o nível Seguro. Para os níveis Moderado e Avançado, confirme
que a **Proteção do Sistema** está ligada em Sistema › Proteção do Sistema, e reserve
tempo: a limpeza de componentes sozinha pode passar de vinte minutos.

---

## 3. Níveis de limpeza

### Nível Seguro

Remove somente o que é promocional, foi descontinuado pela Microsoft ou não tem função
no uso comum de um computador pessoal ou de trabalho.

| | |
|---|---|
| **Objetivo** | Devolver o Windows ao que ele seria sem os acordos comerciais de pré-instalação |
| **Público** | Qualquer pessoa. É o nível recomendado por padrão |
| **Cenários ideais** | Computador recém-comprado com aplicativos de fabricante; máquina após uma atualização grande do Windows que reintroduziu itens promocionais; equipamento de trabalho que precisa parar de sugerir aplicativos |
| **Benefícios** | Menos processos em segundo plano, menu Iniciar sem sugestões e anúncios, alguns GB liberados quando somado à limpeza de componentes |
| **Possíveis impactos** | Se você usa o aplicativo Mapas, o Skype pré-instalado ou o Solitaire, eles saem. Todos voltam pela Microsoft Store |
| **Quando usar** | Sempre que a máquina for nova, ou como manutenção anual |
| **Quando evitar** | Não há cenário em que este nível seja desaconselhado, desde que a simulação tenha sido lida |
| **Grau de segurança** | **Alto.** Nada que o Windows precise para funcionar está no escopo |
| **Tempo médio** | 2 a 5 minutos, sem a limpeza de componentes |
| **Reinicialização** | Recomendada, não obrigatória |
| **Recursos do Windows afetados** | Aplicativos da loja pré-instalados, cinco serviços sem uso doméstico, oito tarefas de coleta, sugestões da interface, busca web no menu Iniciar |

### Nível Moderado

Acrescenta ao Seguro os aplicativos que fazem parte da experiência padrão do Windows,
mas que muita gente substitui por alternativas próprias.

| | |
|---|---|
| **Objetivo** | Enxugar a instalação para quem já usa programas próprios para foto, vídeo, email e jogos |
| **Público** | Usuário que sabe quais aplicativos usa e quais nunca abriu |
| **Cenários ideais** | Máquina de trabalho onde Xbox e player de mídia não fazem sentido; computador com pouco espaço; usuário que já usa Outlook do Office, Chrome, VLC ou similares |
| **Benefícios** | Redução perceptível de processos em segundo plano e de itens no menu Iniciar |
| **Possíveis impactos** | Fotos, Câmera, Email, Calendário, Groove e Filmes saem. Se algum deles for o padrão para abrir um tipo de arquivo, o Windows passará a perguntar qual programa usar. Serviços do Xbox vão para Manual, o que pode atrasar o primeiro login em jogos da loja |
| **Quando usar** | Depois de rodar o nível Seguro e confirmar que ficou tudo bem |
| **Quando evitar** | Se você usa o aplicativo Fotos como visualizador padrão, a Câmera do notebook, ou joga títulos da Microsoft Store |
| **Grau de segurança** | **Médio.** Nada quebra, mas hábitos mudam |
| **Tempo médio** | 5 a 10 minutos, sem a limpeza de componentes |
| **Reinicialização** | Recomendada |
| **Recursos do Windows afetados** | Tudo do Seguro, mais a suíte Xbox, aplicativos de mídia e imagem, Email e Calendário, geolocalização, relatório de erros e o Superfetch em SSD |

### Nível Avançado

Acrescenta itens que alteram comportamentos centrais do sistema. Feito para quem sabe
exatamente o que está desligando.

| | |
|---|---|
| **Objetivo** | Máxima redução de superfície, aceitando perda de funcionalidades do próprio Windows |
| **Público** | Administradores de sistema e usuários experientes |
| **Cenários ideais** | Máquina dedicada a uma função única, como um terminal de ponto de venda ou uma estação de captura; ambiente onde a indexação é indesejada por política |
| **Benefícios** | Menor consumo de I/O e memória em segundo plano; imagem do Windows compactada ao mínimo |
| **Possíveis impactos** | **A busca do menu Iniciar para de funcionar** — digitar o nome de um programa deixa de encontrá-lo. A Ferramenta de Captura e a Calculadora saem. O `/ResetBase` no DISM **impede desinstalar as atualizações do Windows já aplicadas**, de forma definitiva |
| **Quando usar** | Somente com objetivo claro e depois de ler a simulação inteira |
| **Quando evitar** | Em máquina de uso geral, de outra pessoa, ou em qualquer computador onde você não possa reinstalar o Windows se algo der errado |
| **Grau de segurança** | **Baixo.** Não corrompe o sistema, mas remove funcionalidades que a maioria espera ter |
| **Tempo médio** | 20 a 45 minutos, com a limpeza de componentes |
| **Reinicialização** | **Obrigatória** |
| **Recursos do Windows afetados** | Tudo dos níveis anteriores, mais indexação, teclado virtual, Ferramenta de Captura, Calculadora e o armazenamento de componentes com `/ResetBase` |

> **Sobre a busca do Iniciar.** Desativar o serviço `WSearch` não remove o menu Iniciar
> nem impede abrir programas pela lista. O que para de funcionar é a busca por
> digitação. Para reverter, use a opção de reversão do módulo ou reative o serviço
> Windows Search em Serviços.

---

## 4. Submódulos

Cada submódulo pode ser executado isoladamente pelo submenu, sem passar pela rotina
completa.

### 4.1 Aplicativos

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[5]` |
| **Ação interna** | `-Action Apps` |
| **Finalidade** | Remover aplicativos da Microsoft Store instalados sem escolha do usuário |
| **O que remove** | 129 famílias no total: aplicativos Bing, suíte 3D descontinuada, Skype pré-instalado, Mapas, Feedback Hub, Teams pessoal, Clipchamp, Cortana, Office Hub; a coleção de jogos casuais da Microsoft (Solitaire, Mahjong, Sudoku, Jigsaw, Minesweeper, Treasure Hunt, Ultimate Word Games); o aplicativo Copilot e os pacotes de IA que o acompanham no Windows 11; e pré-instalados de terceiros como LinkedIn, WhatsApp, streaming, redes sociais, jogos e versões de avaliação de antivírus e VPN |
| **Componentes envolvidos** | Subsistema Appx do Windows, via `Get-AppxPackage`, `Remove-AppxPackage` e `Remove-AppxProvisionedPackage` |
| **Impacto esperado** | Menos itens no menu Iniciar, menos processos em segundo plano, alguns centenas de MB liberados |
| **Dependências** | Módulo `Appx`. Sem ele, a categoria é ignorada com aviso |
| **Compatibilidade** | Windows 10 1607 ou superior e Windows 11, todas as edições |
| **Reversão** | **Parcial.** O Windows não retém o pacote no disco após a remoção. A reversão lista o que foi removido, para reinstalação pela Microsoft Store |
| **Observações** | A remoção é feita para todos os usuários e também no provisionamento, o que impede a reinstalação automática em contas novas. Pacotes casados por curinga são reconferidos pelo nome real antes da remoção, para que um curinga amplo não arraste um pacote protegido |

### 4.2 Serviços

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[6]` |
| **Ação interna** | `-Action Services` |
| **Finalidade** | Reduzir serviços em execução sem afetar funções essenciais |
| **O que altera** | 15 serviços, cada um para um tipo de inicialização específico — nenhum é excluído |

| Serviço | Nível | Passa a | O que deixa de funcionar |
|---|---|---|---|
| `MapsBroker` | Seguro | Desativado | Atualização de mapas offline |
| `RetailDemo` | Seguro | Desativado | Modo de demonstração de loja |
| `WMPNetworkSvc` | Seguro | Desativado | Compartilhamento de mídia do Media Player |
| `Fax` | Seguro | Desativado | Envio de fax por modem analógico |
| `RemoteRegistry` | Seguro | Desativado | Acesso remoto ao registro |
| `PrintNotify` | Seguro | Manual | Notificações de impressora. A fila continua funcionando |
| `WerSvc` | Moderado | Manual | Envio automático de relatórios de erro |
| `lfsvc` | Moderado | Manual | Geolocalização para aplicativos de clima e mapas |
| `XblAuthManager` | Moderado | Manual | Autenticação Xbox Live |
| `XblGameSave` | Moderado | Manual | Salvamento de jogos na nuvem |
| `XboxNetApiSvc` | Moderado | Manual | Rede do Xbox Live |
| `XboxGipSvc` | Moderado | Manual | Acessórios Xbox por USB |
| `SysMain` | Moderado | Desativado | Superfetch. **Só é aplicado em SSD** |
| `WSearch` | Avançado | Desativado | Busca por digitação no menu Iniciar |
| `TabletInputService` | Avançado | Manual | Teclado virtual e escrita a caneta |

| | |
|---|---|
| **Componentes envolvidos** | Gerenciador de Serviços, via `Get-Service` e `Set-Service` |
| **Impacto esperado** | Menos memória residente e menos I/O em segundo plano |
| **Dependências** | Nenhuma além do privilégio administrativo |
| **Compatibilidade** | Serviços ausentes em um build específico são ignorados sem erro |
| **Reversão** | **Completa.** Tipo de inicialização e estado anterior são gravados e restaurados |
| **Observações** | O `SysMain` é preservado em disco mecânico, onde o Superfetch traz ganho real. A decisão é tomada em tempo de execução pelo tipo de mídia do disco, e o motivo aparece no relatório |

### 4.3 Tarefas agendadas

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[6]` (executado junto com os serviços) |
| **Ação interna** | `-Action Tasks` |
| **Finalidade** | Desativar tarefas de coleta e de manutenção sem função no uso comum |
| **O que altera** | 14 tarefas, todas apenas desativadas — nenhuma é excluída |
| **Principais alvos** | Coleta de dados de aplicativos de inicialização, banco de compatibilidade, envio de relatórios de erro, experiência de nuvem na primeira execução, notificações e atualização de mapas, limpeza do modo demonstração, coleta de feedback por cenário, diagnóstico de disco, controle dos pais e telemetria do Office |
| **Componentes envolvidos** | Agendador de Tarefas, via `Get-ScheduledTask` e `Disable-ScheduledTask` |
| **Impacto esperado** | Menos processos acordando em segundo plano |
| **Dependências** | Módulo `ScheduledTasks`. Sem ele, a categoria é ignorada com aviso |
| **Compatibilidade** | Tarefas inexistentes no build são ignoradas sem erro |
| **Reversão** | **Completa.** O estado anterior é gravado e a tarefa é reativada |
| **Observações** | As seis tarefas de telemetria clássica **não** estão aqui: pertencem ao módulo Telemetry, menu `[4]` › `[2]`. Duplicá-las criaria duas fontes de verdade para o mesmo alvo |

### 4.4 Privacidade

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[7]` |
| **Ação interna** | `-Action Privacy` |
| **Finalidade** | Desligar sugestões, conteúdo promocional e coleta implícita na interface |
| **O que altera** | 30 valores de registro |
| **Principais efeitos** | Fim da instalação silenciosa de aplicativos promovidos; fim das sugestões no menu Iniciar, na tela de bloqueio e em Configurações; fim da reinstalação automática de aplicativos de fabricante; busca web desligada no menu Iniciar; coleta implícita de texto digitado e de escrita a caneta restrita; experiências personalizadas por diagnóstico desligadas; Copilot, Recall e Widgets desligados no Windows 11 |
| **Componentes envolvidos** | `ContentDeliveryManager`, `Privacy`, `UserProfileEngagement`, `InputPersonalization`, `Search`, políticas de `Windows Search`, `CloudContent`, `WindowsCopilot`, `WindowsAI`, `Explorer` e `Dsh` |
| **Impacto esperado** | Interface sem publicidade e sem reinstalação automática de aplicativos |
| **Dependências** | Nenhuma |
| **Compatibilidade** | Algumas políticas de `CloudContent` são ignoradas na edição Home por desenho da Microsoft. O módulo grava o valor mesmo assim, sem erro |
| **Reversão** | **Completa.** O valor anterior é gravado. Valores que não existiam antes são **removidos** na reversão, e não zerados |
| **Observações** | Complementa o módulo Telemetry sem repetir nenhuma das cinco chaves que ele já controla |

#### Copilot, Recall e Widgets

Nenhum dos três é um interruptor único: existem como aplicativo, como política de
máquina, como botão do shell e como recurso. Remover só o aplicativo deixa o botão na
barra e a política ausente, e a experiência volta na atualização seguinte. Por isso
cada camada é um item próprio:

| Camada | Nível | O que faz |
|---|---|---|
| Aplicativo Copilot e pacotes de IA que o acompanham | Seguro | Remove os pacotes; reinstaláveis pela Microsoft Store |
| `TurnOffWindowsCopilot` (máquina e usuário) | Moderado | Desliga o Copilot por política |
| `ShowCopilotButton` | Moderado | Oculta o botão na barra de tarefas |
| `DisableAIDataAnalysis` e `AllowRecallEnablement` | Moderado | Desligam o Recall e impedem que ele volte por atualização |
| `AllowNewsAndInterests` e `TaskbarDa` | Moderado / Seguro | Desligam os Widgets |

O pacote dos Widgets (`MicrosoftWindows.Client.WebExperience`) **não é removido**: ele
cai no prefixo protegido do shell do Windows 11. Desligar por política é reversível e
não expõe o shell — na dúvida, o módulo não remove.

Todas essas chaves têm build mínima declarada. Numa máquina Windows 10, ou num Windows
11 anterior à build em que o recurso existe, elas saem como `NaoSuportado` com o motivo,
em vez de serem gravadas sem efeito.

Desligar o Recall **aumenta** a privacidade e não desativa nenhum controle de
segurança do Windows.

### 4.5 Ajustes opcionais

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[7]` (executado junto com privacidade) |
| **Ação interna** | `-Action Tweaks` |
| **Finalidade** | Aplicar preferências de interface e de sistema que a maioria dos usuários prefere |
| **O que altera** | 10 valores de registro |
| **Principais efeitos** | Extensões de arquivo passam a ser exibidas, o que reduz o risco de abrir um executável disfarçado; Explorer abre em Este Computador; botões de Visão de Tarefas, Widgets e Chat ocultados; Notícias e Interesses desativado; anúncios do OneDrive dentro do Explorer desligados; atualização de último acesso do NTFS desativada |
| **Componentes envolvidos** | `Explorer\Advanced`, políticas de `Windows Feeds`, `SmartActionPlatform`, políticas do sistema de arquivos |
| **Impacto esperado** | Interface mais limpa e ligeiramente menos escrita em disco |
| **Dependências** | Nenhuma |
| **Compatibilidade** | `TaskbarDa` e `TaskbarMn` só têm efeito no Windows 11. No Windows 10 são gravados sem efeito visível |
| **Reversão** | **Completa** |
| **Observações** | Alterações de interface exigem reiniciar o Explorer, menu `[5]` › `[4]`, ou fazer novo login |

### 4.6 Componentes obsoletos

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[8]` |
| **Ação interna** | `-Action Components` |
| **Finalidade** | Compactar o armazenamento de componentes, que cresce a cada atualização |
| **O que faz** | Analisa o WinSxS e remove as versões superadas de componentes substituídos por atualizações |
| **Componentes envolvidos** | DISM, com `/AnalyzeComponentStore` e `/StartComponentCleanup`. No nível Avançado, também `/ResetBase` |
| **Impacto esperado** | De centenas de MB a vários GB liberados, conforme o tempo desde a instalação |
| **Dependências** | `Dism.exe`, presente em toda instalação do Windows |
| **Compatibilidade** | Windows 10 e 11, todas as edições |
| **Reversão** | **Nenhuma.** A remoção de componentes superados é definitiva por natureza |
| **Observações** | Com `/ResetBase`, as atualizações já instaladas deixam de ser desinstaláveis. Se houver reinício pendente, a operação pode falhar — reinicie e repita. Arquivos temporários e caches são tratados pelo módulo Cleanup, menu `[4]` › `[1]` |

### 4.7 Backup, ponto de restauração e reversão

| | |
|---|---|
| **Menu** | `[4]` › `[9]` › `[9]` |
| **Ações internas** | `-Action Backup`, `-Action RestorePoint`, `-Action Restore` |
| **Finalidade** | Garantir caminho de volta antes e depois das alterações |
| **O que faz** | **Backup** grava o estado atual de todos os alvos do catálogo presentes na máquina, sem alterar nada. **Ponto de restauração** cria um ponto do Windows. **Reversão** devolve serviços, tarefas e registro ao estado gravado |
| **Componentes envolvidos** | `Checkpoint-Computer`, `Enable-ComputerRestore` e o manifesto JSON do próprio módulo |
| **Impacto esperado** | Nenhum. São operações de segurança |
| **Dependências** | Proteção do Sistema ligada, para o ponto de restauração |
| **Compatibilidade** | O Windows limita a um ponto de restauração a cada 24 horas. O módulo reconhece essa recusa e trata o ponto recente como válido |
| **Reversão** | Não se aplica |
| **Observações** | Existe simulação de reversão, `[4]` › `[9]` › `[9]` › `[3]`, que mostra o que seria restaurado sem restaurar |

---

## 5. Listas de proteção

Existe um conjunto de itens que o módulo **nunca** toca, em nenhum nível.

| Categoria | Quantidade | Exemplos |
|---|---:|---|
| Aplicativos por nome exato | 48 | Microsoft Store, Defender, autenticação de conta, shell do menu Iniciar, codecs de mídia, Edge |
| Aplicativos por prefixo de família | 7 | `Microsoft.VCLibs.`, `Microsoft.NET.Native.`, `Microsoft.UI.Xaml.`, `MicrosoftWindows.Client.` |
| Serviços | 56 | Windows Update, Defender, firewall, log de eventos, RPC, áudio, rede, perfil de usuário, instalador |
| Ramos de registro | 4 | `HKLM:\SYSTEM\CurrentControlSet\Services`, `Control`, `SECURITY`, `SAM` |

**A proteção tem precedência absoluta.** Ela é avaliada **depois** de qualquer filtro
do operador, inclusive do parâmetro `-Include`. Isso é deliberado: nem quem opera a
ferramenta consegue contorná-la por parâmetro.

### Classificação de risco

Todo item do relatório carrega uma **classe**, que responde "o que é este alvo" — eixo
diferente do **resultado**, que responde "o que aconteceu com ele".

| Classe | Significado |
|---|---|
| `ESSENCIAL` | Remover quebra loja, logon, shell, rede ou atualização |
| `SISTEMA` | Componente de sistema, pacote não removível ou tarefa do próprio Windows |
| `SEGURANCA` | Valor que sustenta defesa, UAC ou criptografia |
| `DEPENDENCIA` | Framework ou pacote de recurso do qual outros dependem |
| `RECOMENDADO_PRESERVAR` | Alto impacto; só entra com `-Include` explícito |
| `DEBLOAT_SEGURO` | Elegível a partir do nível Seguro |
| `DEBLOAT_MODERADO` | Elegível a partir do nível Moderado |
| `OPCIONAL` | Elegível apenas no nível Avançado |
| `INEXISTENTE` | O alvo não está no sistema |
| `INCOMPATIVEL` | Não existe nesta build ou edição do Windows |
| `ERRO` | Tentativa executada e não confirmada |

As quatro primeiras nunca vêm do catálogo — são atribuídas pelas listas de proteção. Um
item assim aparece no relatório com resultado `Protegido` e a classe explicando por quê,
em vez de simplesmente desaparecer da lista.

---

## 6. Reversão

### O manifesto

Toda execução que altera algo grava um manifesto em JSON com o **estado anterior** de
cada item, em dois lugares:

| Local | Finalidade |
|---|---|
| `COMPARTDISK_Relatorios\<sessão>\Debloat_Manifesto_<sessão>.json` | Junto dos relatórios da sessão |
| `COMPARTDISK_Restauracao\Debloat_Manifesto_<sessão>.json` | Fora do diretório de sessão, para sobreviver a execuções futuras |

A reversão usa o manifesto mais recente, ou um específico se indicado.

### O que volta e o que não volta

| Tipo | Reversão | Como |
|---|---|---|
| Serviços | Completa | Tipo de inicialização e estado restaurados ao valor exato anterior |
| Tarefas agendadas | Completa | Reativadas ao estado anterior |
| Registro | Completa | Valor anterior regravado. Se o valor **não existia**, ele é removido — e não zerado, o que seria uma configuração nova disfarçada de reversão |
| Aplicativos | **Parcial** | Apenas listados. O Windows não retém o pacote no disco após a remoção |
| Componentes (WinSxS) | **Nenhuma** | Definitiva por natureza |

### O ponto de restauração

A rotina completa cria um ponto de restauração antes de qualquer alteração e
**interrompe a execução** se não conseguir criá-lo. É possível dispensá-lo
explicitamente, assumindo o risco.

Se o Windows recusar por já existir um ponto nas últimas 24 horas, o módulo reconhece
essa recusa e prossegue, tratando o ponto recente como válido.

---

## 7. Uso avançado

O módulo pode ser chamado diretamente, fora do menu.

```powershell
# Simulação completa, sem alterar nada
powershell -ExecutionPolicy Bypass -File Modules\Debloat.ps1 -Action Analyze -Level Moderate

# Somente aplicativos, no nível Seguro, preservando a família Xbox
powershell -ExecutionPolicy Bypass -File Modules\Debloat.ps1 -Action Apps -Exclude '*Xbox*'

# Somente os itens de privacidade, simulando
powershell -ExecutionPolicy Bypass -File Modules\Debloat.ps1 -Action Privacy -DryRun

# Rotina completa sem ponto de restauração, por conta e risco
powershell -ExecutionPolicy Bypass -File Modules\Debloat.ps1 -Action Full -Level Safe -SkipRestorePoint

# Reverter a partir de um manifesto específico
powershell -ExecutionPolicy Bypass -File Modules\Debloat.ps1 -Action Restore -ManifestPath "C:\...\Debloat_Manifesto_20260805_143000.json"
```

### Parâmetros

| Parâmetro | Valores | Padrão | Descrição |
|---|---|---|---|
| `-Action` | `Analyze`, `Apps`, `Services`, `Tasks`, `Privacy`, `Tweaks`, `Components`, `Full`, `Backup`, `Restore`, `RestorePoint` | `Analyze` | O que executar |
| `-Level` | `Safe`, `Moderate`, `Aggressive` | `Safe` | Até que nível de risco incluir |
| `-Include` | Lista de padrões | vazio | Restringe aos itens que casarem, por id, alvo ou categoria |
| `-Exclude` | Lista de padrões | vazio | Remove da seleção os itens que casarem |
| `-DryRun` | — | desligado | Simula qualquer ação, sem alterar nada |
| `-SkipRestorePoint` | — | desligado | Dispensa o ponto de restauração na rotina completa |
| `-ManifestPath` | Caminho | vazio | Manifesto específico para a reversão |
| `-Quiet` | — | desligado | Suprime o cabeçalho e o rodapé na saída |

### Códigos de saída

| Código | Significado |
|---|---|
| `0` | Concluído sem ressalvas |
| `1` | Concluído com avisos |
| `2` | Erro tratado |
| `3` | Recurso não suportado neste hardware ou edição |

---

## 8. Sem PowerShell

Quando o PowerShell está ausente ou bloqueado por política, o Launcher usa rotinas
Batch equivalentes. A cobertura é parcial e a ferramenta informa isso.

| Categoria | Cobertura em Batch | Ferramenta usada |
|---|---|---|
| Serviços | Subconjunto seguro | `sc.exe` |
| Tarefas agendadas | Subconjunto seguro | `schtasks.exe` |
| Privacidade e ajustes | Subconjunto seguro | `reg.exe` |
| Componentes | Completa | `dism.exe` |
| Ponto de restauração | Completa | `wmic.exe` |
| **Aplicativos** | **Não disponível** | Depende do subsistema Appx |
| **Simulação e manifesto** | **Não disponível** | Dependem do catálogo em PowerShell |

Sem PowerShell, portanto, **não há reversão automática**. Use Configurações ›
Aplicativos para remover aplicativos manualmente.

---

## 9. Perguntas frequentes

**Posso rodar mais de uma vez?**
Sim. Itens já no estado desejado são reportados como `JaAplicado` e nada é feito
novamente.

**Removi algo que uso. E agora?**
Se for serviço, tarefa ou ajuste, use a reversão em `[4]` › `[9]` › `[9]` › `[4]`. Se
for aplicativo, reinstale pela Microsoft Store — o nome exato está no relatório.

**Por que um item apareceu como "Protegido"?**
Ele casou com uma lista de proteção. Isso é o comportamento correto e não indica erro.

**Por que o SysMain não foi desativado?**
Porque a máquina tem disco mecânico. O Superfetch traz ganho real nesse hardware, e o
módulo o preserva de propósito.

**A limpeza de componentes falhou. O que fazer?**
Quase sempre é reinício pendente. Reinicie e execute novamente `[4]` › `[9]` › `[8]`.

**Isso substitui a limpeza de disco?**
Não. São coisas diferentes. Use `[4]` › `[1]` para arquivos temporários e caches.

---

## Documentos relacionados

| Documento | Conteúdo |
|---|---|
| [Descrição dos Menus](MENUS.md) | Mapa completo das telas, incluindo os submenus do desbloat |
| [Manual do Usuário](MANUAL-DO-USUARIO.md) | Explicação de cada opção em linguagem simples |
| [Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md) | Execução desassistida e parque de máquinas |
| [Manual Técnico](MANUAL-TECNICO.md) | Contrato dos módulos e convenções de código |
| [Limitações Conhecidas](LIMITACOES.md) | O que a ferramenta não faz, e por quê |
| [Boas Práticas](BOAS-PRATICAS.md) | Como utilizar com segurança |

---

**DESENVOLVIDO POR EDSILAS**
