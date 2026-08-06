# Histórico de Mudanças — COMPARTDISK

Todas as mudanças relevantes do projeto são registradas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o
versionamento segue [Versionamento Semântico](https://semver.org/lang/pt-BR/).

---

## [1.3.1] — 2026-08-06

Versão de correção. **Nenhuma tecla de menu mudou de posição, nenhuma ação foi
adicionada ou removida, nenhuma assinatura de função pública foi alterada.**

### Corrigido

#### Crítico

- **Submenus executavam opções que o usuário não escolheu.** `if errorlevel N`
  significa "maior ou igual a N", e os oito submenus usavam `call`, que retorna e
  deixa o encadeamento continuar contra o código de saída do módulo. Um módulo que
  saía com `WARN` (1), `ERROR` (2) ou `UNSUPPORTED` (3) reativava os testes de baixo.
  Exemplo reproduzível: `[3]` › `[5]` "Testar Conectividade" numa máquina sem
  internet devolvia `WARN`, e a redefinição completa da pilha de rede — que não pede
  confirmação — era executada em seguida. A tecla escolhida passa a ser congelada em
  `MENU_OPC` e comparada por igualdade.

#### Alto

- **`Defender.ps1`** afirmava "Histórico de ameaças limpo" quando
  `Get-MpThreatDetection` falhava — situação comum com o Defender em modo passivo.
  Consulta recusada passa a ser reportada como não verificada.
- **`Explorer.ps1`** encerrava o shell para limpar o cache de ícones e o reiniciava
  com uma única tentativa e erro silenciado, informando sucesso. Passa a usar a mesma
  verificação com três tentativas de `Restart-ShellExplorer`.
- **`Network.ps1`** gravava o backup do arquivo `hosts` dentro de
  `System32\drivers\etc`, sem verificar o resultado da cópia e anunciando o backup
  sempre. O backup passa a ir para o diretório de relatórios e só é anunciado quando
  o arquivo existe.
- **`Collectors.ps1`** atribuía o prognóstico SMART ao disco errado em máquinas com
  mais de um disco: o casamento `-like "*<id>*"` encontrava o dígito em qualquer
  posição do `InstanceName`. Passa a casar o índice ao final da cadeia.
- **`Collectors.ps1`** truncava a contagem de eventos em 60 por log antes do
  agrupamento, sem informar. O truncamento passa a ser registrado.
- **`Launcher.bat` `:FB_LIMPEZA`** apagava a pasta `Network` dos navegadores
  Chromium, que guarda `Cookies` e `TransportSecurity` — desconectando o usuário de
  todos os sites. O caminho PowerShell nunca a tocou, e `:FB_LIMPEZA_NAVEGADORES`
  também não. As três listas de subcache foram alinhadas.

#### Médio

- `Core.ps1` — `Test-CompartDiskProtectedPath` não cobria a forma `C:` sem barra,
  que o PowerShell resolve como diretório corrente da unidade.
- `Core.ps1` — `Invoke-NativeCommand -PassThruOutput` emitia no stream de sucesso e
  fazia o retorno virar array.
- `Audit.ps1` — as tabelas de discos, volumes e eventos eram capturadas por
  `Invoke-SafeCommand` e nunca chegavam à tela.
- `Audit.ps1` — a seção do Defender sumia do relatório quando a consulta falhava.
- `Collectors.ps1` — eventos ordenados alfabeticamente por nível colocavam os avisos
  à frente dos críticos.
- `Collectors.ps1` — a coluna `SenhaExpira` vinha invertida no caminho de queda WMI.
- `Hardware.ps1` — falta de privilégio para ler sensores ACPI era reportada como
  ausência de sensor no firmware.
- `Hardware.ps1` — WMI degradado produzia o achado "Uso de memória em 0%" com
  severidade OK.
- `Smart.ps1` — discos com `Pred Fail`, `Degraded` ou `NonRecover` no caminho WMI não
  geravam achado algum.
- `Smart.ps1` — a coluna `TamanhoCluster` publicava o tamanho da partição.
- `Users.ps1` — falha ao ler o log de Segurança virava "nenhuma falha de logon".
- `Users.ps1` — nome de conta com curinga podia desativar a guarda de conta Microsoft.
- `Update.ps1` — reexecutar o reset destruía o backup original de
  `SoftwareDistribution`, e a própria ferramenta recomenda reexecutar.
- `Update.ps1` — os serviços eram declarados reconfigurados sem verificação.
- `Performance.ps1` — os efeitos visuais eram alterados mesmo quando a troca do plano
  de energia falhava.
- `Bitlocker.ps1` — a ausência de senha de recuperação era avaliada no conjunto dos
  volumes, e não no volume do sistema.
- `Launcher.bat` — `:TRACE` não higienizava o argumento e quebrava quando o caminho
  da ferramenta continha `&`.
- `Launcher.bat` — `:FB_USERS_SENHA` existia completa e nenhuma linha a chamava.
- `Launcher.bat` — dezessete caminhos `C:\Windows` fixos passaram a `%SystemRoot%`.
- `remote.ps1` — `Set-StrictMode -Version 2.0` e as preferências vazavam para a
  sessão do administrador, porque `iex` executa no escopo do chamador.

#### Baixo

- `Cleanup.ps1` — "Cache DNS limpo" era emitido sem verificação.
- `Debloat.ps1` — a reconfirmação de pacotes protegidos não alcançava os
  provisionados.
- `Debloat.ps1` — `exit` dentro do `try` fazia `Stop-CompartDiskModule` executar duas
  vezes nos caminhos de saída antecipada.
- `Battery.ps1` — o rótulo "Fabricante" exibia o `DeviceID`, e a química da bateria
  saía como código numérico.
- `remote.ps1` — o fallback de extração não limpava um destino parcialmente extraído.

### Documentação

- `LIMITACOES.md` — a afirmação de que a ferramenta "não contata servidores" e "não
  baixa pacotes" foi corrigida: `Test-Internet` contata servidores de teste de
  conectividade e `Update-MpSignature` baixa definições do Defender.
- `LIMITACOES.md` — a limitação "o perfil usado é o de quem elevou" listava três
  operações afetadas; são pelo menos sete.
- `MANUAL-TECNICO.md` — a proteção de caminhos é por igualdade exata, não
  hierárquica.
- `EXECUCAO-REMOTA.md` — a tabela de tratamento de erros prometia recusa
  incondicional por SHA-256, contradizendo a nota da seção 3.

---

## [1.3.0] — 2026-08-05

### Adicionado

- **Módulo de Desbloat (`Modules/Debloat.ps1`).** Onze ações: `Analyze`, `Apps`,
  `Services`, `Tasks`, `Privacy`, `Tweaks`, `Components`, `Full`, `Backup`, `Restore`
  e `RestorePoint`, em três níveis de risco — `Safe`, `Moderate` e `Aggressive`.
  Acessível pelo menu `[4]` › `[9]`. Nenhuma tecla de menu existente mudou de posição.
- **Catálogo declarativo único.** Cada item traz tipo, categoria, nível mínimo, motivo
  técnico e reversibilidade. Simulação, execução e relatório derivam da mesma fonte,
  o que garante que a prévia descreva exatamente o que a execução fará.
- **Listas de proteção com precedência absoluta.** Famílias Appx, prefixos de runtime,
  serviços e ramos de registro protegidos são avaliados depois de `-Include`,
  justamente para que a proteção não possa ser contornada por parâmetro. Pacotes
  casados por curinga são reconferidos pelo nome real antes da remoção.
- **Manifesto de reversão.** Toda alteração registra o estado *anterior* em JSON, em
  duas cópias: no diretório da sessão e em `COMPARTDISK_Restauracao`, fora dela. A
  ação `Restore` devolve serviços, tarefas e registro ao valor exato de origem —
  inclusive removendo valores que não existiam antes, em vez de gravar zero.
- **Ponto de restauração do sistema.** A rotina completa cria um antes de qualquer
  alteração e **aborta** se não conseguir, salvo `-SkipRestorePoint` explícito. Trata
  os dois motivos clássicos de falha: proteção desligada e o intervalo mínimo de 24 h.
- **Validação prévia** de edição do Windows, privilégio, reinício pendente,
  disponibilidade dos módulos Appx e ScheduledTasks e espaço livre em disco.
- **Simulação como padrão.** `Analyze` nunca altera nada, e `-DryRun` aplica a mesma
  proteção a qualquer outra ação.
- **Decisão condicional por hardware.** O `SysMain` é preservado em disco mecânico,
  onde o Superfetch traz ganho real, e só é desativado em SSD.
- Rotinas Batch `:FB_DEBLOAT*` para serviços, tarefas, registro, componentes e ponto
  de restauração, mantendo a promessa de degradação sem PowerShell. A remoção de
  aplicativos não tem equivalente Batch e é informada como tal.

### Documentação

- **`docs/DESBLOAT.md`** — referência completa do módulo: os três níveis com objetivo,
  público, cenários, impactos, grau de segurança, tempo e necessidade de reinício; os
  sete submódulos com o que exatamente alteram, componentes do Windows envolvidos,
  dependências, compatibilidade e reversibilidade; as listas de proteção; o manifesto
  de reversão; parâmetros de linha de comando e a cobertura em modo Batch.
- README ganhou seção própria sobre o desbloat e índice renumerado para treze seções.
- Manual do Usuário explica o módulo em linguagem simples, com o significado de cada
  palavra que aparece na tela durante a execução.
- Manual do Administrador registra por que o módulo não está exposto na linha de
  comando, e como usá-lo em parque quando essa for a decisão.
- Manual Técnico documenta como estender o catálogo, incluindo o motivo de usar chaves
  nomeadas em vez de arrays posicionais.
- Arquitetura passa a declarar as fronteiras entre Cleanup, Telemetry, Performance e
  Debloat, para que não existam duas fontes de verdade sobre o mesmo alvo.
- Guia de Utilização, Boas Práticas, FAQ e Solução de Problemas cobrem o módulo nos
  respectivos recortes.

### Correção de defeitos

Correção de defeitos e endurecimento de guardas de segurança. Nenhuma funcionalidade
foi adicionada ou removida; nenhuma tecla de menu mudou de posição.

### Corrigido

- **Raiz do disco não era reconhecida como caminho protegido.** A lista de proteção
  guardava `C:\` enquanto o alvo era normalizado para `C:`, e a comparação nunca
  casava. O efeito prático era permitir `takeown` e reescrita de ACL recursivos sobre
  todo o volume de sistema. A decisão passou a morar em ponto único no `Core.ps1`
  (`Test-CompartDiskProtectedPath`), com normalização aplicada aos dois lados.
- **Troca de senha travava ao final.** Uma chamada a `Write-Color` sem argumento fazia
  o PowerShell abrir prompt de parâmetro obrigatório logo após a senha ser redefinida.
- **Backup dos logs de eventos era anunciado mesmo quando falhava.** A mensagem de
  êxito e o achado do relatório passaram a refletir quantos logs foram realmente
  exportados antes da limpeza, que é irreversível.
- **`Invoke-NativeCommand` podia travar indefinidamente.** A leitura de saída padrão e
  de erro era sequencial: o processo filho bloqueava ao encher o canal ainda não lido,
  e o tempo limite jamais chegava a ser avaliado. Os dois canais passaram a ser
  drenados de forma concorrente, e o tempo limite tornou-se efetivo.
- **Relatório consolidado duplicava achados.** Consolidar duas vezes na mesma sessão
  reagregava o próprio estado do módulo `Report`, dobrando cada constatação e os
  contadores do resumo executivo.
- **Constatações perdidas quando o mesmo módulo era executado duas vezes.** O arquivo
  de estado era nomeado apenas pelo módulo; a segunda ação sobrescrevia a primeira.
  O nome passou a incluir a ação. Afetava seis opções de menu.
- **Senha em texto claro permanecia em memória.** O `BSTR` gerado na confirmação nunca
  era liberado com `ZeroFreeBSTR`, e a cadeia gerenciada sobrevivia até uma coleta
  futura. Ambos passaram a ser zerados e liberados de forma determinística.
- **Ativação e desativação da conta interna geravam texto malformado** no log e no
  relatório (`habilitarda`, `desabilitarda`).
- **Variável de cor inexistente no relatório HTML.** A classe `.brand` referenciava
  `--accent`, que nunca foi declarada.
- **Fallback de `Write-Color` poluía o valor de retorno.** Ao falhar, a função escrevia
  no fluxo de saída, o que podia transformar o código devolvido por
  `Stop-CompartDiskModule` em um vetor.
- **`Users.ps1` e `remote.ps1` estavam sem marca de ordem de bytes**, contrariando a
  convenção registrada no Manual Técnico.

### Alterado

- **Rotina Batch de contas alinhada ao caminho PowerShell.** A listagem deixou de
  emendar a *remoção* de senha e o encadeamento automático da conta interna de
  Administrador. Agora termina na listagem e exige escolha deliberada, como já
  acontecia com o PowerShell disponível. A auditoria de contas passou a usar uma
  rotina somente leitura.
- **Modo desassistido não abre mais o navegador.** `/audit` e `/report` deixaram de
  exibir o relatório HTML ao final. O modo interativo permanece inalterado.
- **Relatório JSON gravado sem marca de ordem de bytes.** O mesmo arquivo era gerado
  com BOM no Windows PowerShell 5.1 e sem BOM no PowerShell 7. TXT, CSV e HTML não
  mudaram.
- **Limpeza preserva os artefatos da própria ferramenta em `%TEMP%`.** Na execução
  remota o pacote é extraído ali, e a limpeza profunda removia os módulos da instância
  em execução.
- Duas opções que se tornavam silenciosas sem PowerShell — exclusões do Defender e
  troca de senha — passaram a informar a indisponibilidade.
- Nome de conta e caminho digitados no Launcher têm aspas removidas antes de compor
  os argumentos, o que também faz funcionar o texto colado com **Copiar como caminho**
  do Explorer.
- Documentação alinhada ao comportamento real: código de saída do modo desassistido,
  condições da validação SHA-256 e limitação de perfil sob elevação.

---

## [1.2.0] — 2026-07-31

Versão oficial de publicação. Consolida a identidade **COMPARTDISK**, padroniza o
versionamento e entrega a documentação completa.

### Adicionado

- **Execução remota em um comando.** `irm .../remote.ps1 | iex` baixa e executa a
  versão estável mais recente, com validação de integridade por SHA-256 e remoção
  automática dos arquivos temporários. É um método adicional de inicialização: não
  altera nem substitui nenhum fluxo existente.
- Guia de Execução Remota, com passo a passo, tratamento de erros e configuração
  por variáveis de ambiente para espelho interno ou versão fixada.
- Documentação completa pronta para publicação: guias de instalação, configuração e
  utilização, manuais do usuário, do administrador e técnico, FAQ, solução de
  problemas, arquitetura, estrutura, requisitos, compatibilidade, limitações, boas
  práticas, política de atualização e créditos.
- Arquivo de licença (MIT) e histórico de mudanças.
- Assinatura de autoria padronizada em toda a interface, relatórios, logs e documentação.
- Tela **Ambiente de Execução** com identificação de produto, versão e autoria.

### Alterado

- Interface do Launcher redesenhada: fundo escuro de baixo contraste no lugar do azul
  intenso, cor aplicada com parcimônia e hierarquia construída por espaçamento e
  alinhamento. Nenhuma tecla de menu mudou de posição.
- Subtítulo da aplicação padronizado como **Assistente de Reparo**, na janela do
  console e na tela principal.
- Capitalização unificada em títulos, subtítulos, cabeçalhos e rótulos de opção.
  A convenção está registrada no cabeçalho do `Launcher.bat`.
- Mensagens de log com marcador de largura fixa — `[ OK ]`, `[WARN]`, `[ERRO]`,
  `[INFO]` — alinhadas em coluna. O formato gravado em arquivo permanece o anterior.
- Identidade unificada sob o nome **COMPARTDISK**, sem variações ou sufixos de numeração interna.
- Versão padronizada em **1.2.0** em todos os pontos: launcher, menus, título da janela,
  banners, cabeçalhos de arquivo, relatórios, logs e documentação.
- Banner do menu principal recentralizado para 80 colunas exatas.

### Mantido

- Nenhuma funcionalidade removida ou alterada.
- Estrutura de menus, sequências de teclas e fluxos de execução preservados integralmente.
- Compatibilidade com Windows 10 e Windows 11 inalterada.

---

## [1.1.0] — 2026-07-31

Correção de falha crítica de inicialização e endurecimento da partida.

### Corrigido

- **Log vazio.** Mensagens contendo `|` eram expandidas antes do reconhecimento de
  operadores pelo interpretador de comandos, transformando a linha de log em uma
  cadeia de comandos inválida. O arquivo de log ficava com apenas o separador. O
  escritor de log agora higieniza `|`, `&`, `<` e `>` na origem.
- **Janela fechando logo após o UAC.** A detecção de privilégio usava apenas
  `net session`, que falha quando o serviço *Server* está parado ou desabilitado —
  comum em Windows Home e imagens corporativas. Um administrador legítimo era
  tratado como usuário comum e a ferramenta se relançava em ciclo.

### Adicionado

- Detecção de privilégio em camadas: `fltmc`, depois `net session`, depois escrita de teste em `HKLM`.
- Sentinela interna de reentrada, que torna o ciclo de reelevação estruturalmente impossível.
- Janela protegida: em falha catastrófica a janela permanece aberta exibindo o erro.
- Trace de inicialização em `%TEMP%\COMPARTDISK_Bootstrap.log`, com doze estágios numerados.
- Detecção automática de encerramento anormal na execução anterior.
- Fallback de diretório de log em três níveis: pasta do programa, Área de Trabalho, pasta temporária.
- Degradação para texto puro quando o console não aceita cores.
- Elevação por `cscript` explícito, com PowerShell como segunda via e instrução manual como terceira.
- Verificação de *Command Extensions* na partida.

---

## [1.0.0] — 2026-07-30

Primeira versão da arquitetura modular.

### Adicionado

- Arquitetura híbrida: Batch como interface e controle de fluxo, PowerShell como
  motor de operações complexas.
- Dezenove módulos PowerShell: biblioteca central, coletores e dezessete módulos de domínio.
- Relatórios em TXT, CSV, JSON e HTML, com resumo executivo e seções colapsáveis.
- Relatório HTML totalmente offline, sem dependência de internet ou fontes externas.
- Rotina Batch equivalente para cada função, usada quando o PowerShell está indisponível.
- Modo desassistido por linha de comando.
- Registro estruturado com data, hora, computador, usuário, versão do Windows, módulo,
  tempo de execução, resultado e rastreamento de exceção.
- Modo de simulação de limpeza, que mede o espaço recuperável sem apagar nada.
- Restauração de telemetria e de plano de energia ao padrão do Windows.
- Backup automático antes de operações destrutivas.

### Corrigido em relação à ferramenta original em Batch

- Verificação de disco não depende mais de confirmação por idioma do Windows.
- Conta interna de Administrador localizada pelo identificador de segurança, e não
  pelo nome — funciona em qualquer idioma do sistema.
- Reset do Windows Update renomeia as pastas em vez de apagá-las, permitindo reversão.

---

[1.3.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.3.0
[1.2.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.2.0
[1.1.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.1.0
[1.0.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.0.0
