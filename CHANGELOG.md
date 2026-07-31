# Histórico de Mudanças — COMPARTDISK

Todas as mudanças relevantes do projeto são registradas aqui.

O formato segue [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/) e o
versionamento segue [Versionamento Semântico](https://semver.org/lang/pt-BR/).

---

## [1.2.0] — 2026-07-31

Versão oficial de publicação. Consolida a identidade **COMPARTDISK**, padroniza o
versionamento e entrega a documentação completa.

### Adicionado

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

[1.2.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.2.0
[1.1.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.1.0
[1.0.0]: https://github.com/edsilas/compartdisk/releases/tag/v1.0.0
