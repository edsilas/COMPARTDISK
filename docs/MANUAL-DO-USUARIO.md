# Manual do Usuário

**COMPARTDISK 1.4.6** · Desenvolvido por Edsilas

Manual escrito para quem **não é técnico**. Cada recurso é explicado em linguagem
simples: o que faz, quando usar e o que esperar.

---

## Índice

1. [Antes de começar](#antes-de-começar)
2. [Abrindo a ferramenta](#abrindo-a-ferramenta)
3. [Entendendo a tela](#entendendo-a-tela)
4. [O que cada opção faz](#o-que-cada-opção-faz)
5. [Os relatórios](#os-relatórios)
6. [Perguntas rápidas](#perguntas-rápidas)

---

## Antes de começar

### Três coisas para saber

**1. A ferramenta precisa de permissão de administrador.** Sem isso, o Windows
recusa quase tudo que ela tenta fazer. Ela pede essa permissão sozinha ao abrir.

**2. Nem tudo pode ser desfeito.** Algumas opções apagam arquivos ou alteram
configurações de forma permanente. Este manual sinaliza claramente quais são.

**3. Comece observando.** Antes de consertar, use as opções que apenas mostram
informações. Elas não mudam nada e ajudam a entender o problema real.

### Se é um computador da empresa

Fale com o setor de TI antes de usar as opções do menu **Segurança**. Elas podem
desfazer configurações que a empresa aplicou de propósito.

---

## Abrindo a ferramenta

1. Abra a pasta onde você descompactou o COMPARTDISK.
2. Clique com o botão direito no arquivo **`Launcher.bat`**.
3. Escolha **Executar como administrador**.
4. Na janela azul do Windows que aparece, clique em **Sim**.

Uma janela preta e azul se abre com o menu. É por ali que você trabalha.

> Se aparecer "O Windows protegeu o computador", clique em **Mais informações** e
> depois em **Executar assim mesmo**. Veja o [Guia de Instalação](INSTALACAO.md).

---

## Entendendo a tela

```
  COMPARTDISK  1.4.6
  Assistente de Reparo

  --------------------------------------------------------------------------

   [1]  Reparo Geral Automatico (One-Click Fix)
   [2]  Aplicativos: Atualizar e Instalar (Winget)
   [3]  Rede, Internet e Conectividade
   [4]  Otimizacao, Limpeza Profunda e Privacidade
   [5]  Reparo do Sistema, Windows Update e Explorer
   [6]  Contas, Permissoes e Seguranca
   [7]  Discos, Drivers e Auditoria de Hardware
   [8]  Diagnostico Avancado e Relatorios (TXT/CSV/JSON/HTML)
   [9]  Ambiente de Execucao e Capacidades

   [0]  Sair e Salvar Relatorio

  --------------------------------------------------------------------------
  Motor: Windows PowerShell 5.1
  Log:   C:\COMPARTDISK\Relatorio_Manutencao.txt
  DESENVOLVIDO POR EDSILAS

  Opcao: 
```

**Para escolher**, aperte o número. Só o número — não precisa apertar Enter.

**Para voltar**, aperte `0`.

**A linha "Motor"** diz qual mecanismo está em uso. Se disser "Batch", o PowerShell
não está disponível: tudo continua funcionando, com diagnóstico mais simples.

**A linha "Log"** mostra onde está sendo gravado o registro do que você fez.

### As cores das mensagens

| Cor | Quer dizer |
|---|---|
| 🟢 Verde | Funcionou |
| 🟡 Amarelo | Funcionou, mas leia o aviso |
| 🔴 Vermelho | Não funcionou |
| 🔵 Ciano | Está em andamento |

---

## O que cada opção faz

### `1` Reparo Geral Automático

**O que é:** o "conserte tudo". Executa sete rotinas de reparo em sequência, sem
perguntar nada.

**Quando usar:** quando o computador está com vários problemas e você não sabe por
onde começar.

**O que esperar:** de 20 a 60 minutos. A tela pode ficar parada por longos períodos —
é normal. Ao terminar, **reinicie o computador**.

**Altera o sistema?** Sim, bastante.

---

### `2` Aplicativos

Abre uma tela com três opções, na ordem em que costumam ser usadas: `1` verificar o
WinGet, `2` a Central de Aplicativos e `3` atualizar. A tecla `0` volta.

#### `2` › `1` Verificar / preparar WinGet

**O que é:** as outras duas opções deste menu dependem do **WinGet**, o gerenciador de
pacotes que acompanha o Windows. Esta opção verifica se ele está lá e funcionando — e,
quando não está, tenta prepará-lo.

**Quando usar:** quando aparecer o aviso de que o WinGet está indisponível, ou antes
de preparar uma máquina, para conferir.

**O que esperar:** primeiro um diagnóstico na tela — versão do Windows, App Installer,
versão do WinGet, fontes, Microsoft Store e política. Depois, conforme o caso:

| Situação | O que a ferramenta faz |
|---|---|
| Já está funcionando | Diz isso e não mexe em nada |
| Instalado, mas sem funcionar | Registra o pacote de novo, **sem baixar nada** |
| Ausente | Abre a página oficial do App Installer na Microsoft Store, para você concluir |
| Desatualizado | Abre a tela de atualizações da Microsoft Store |
| Bloqueado pela empresa | Informa e para. Nenhuma política é alterada |
| Windows antigo demais | Informa o requisito e para |

Ao final, a ferramenta **confere de verdade** se o WinGet passou a funcionar, e só
então oferece voltar para instalar ou atualizar aplicativos.

> Nada é baixado de sites de terceiros, e nenhuma proteção do Windows é desativada
> para isso funcionar.

#### `2` › `2` Central de Aplicativos

**O que é:** procura qualquer aplicativo pelo nome e instala. Você não precisa saber
nenhum comando nem o nome técnico do pacote.

**Quando usar:** sempre que quiser instalar um programa — um navegador, um leitor de
PDF, um compactador, uma ferramenta de diagnóstico, o que for.

**O que esperar:** a tela pede o nome do aplicativo. **Não precisa acertar o nome**
**exato**: `crome` encontra o Google Chrome, `7 zip` encontra o 7-Zip, `vs code`
encontra o Visual Studio Code. Maiúsculas, acentos, espaços e erros pequenos de
digitação não atrapalham.

Em seguida aparece uma lista numerada, separada em **Melhores resultados** e **Mais**
**resultados relacionados**. Em cima ficam os que respondem direto ao que você pediu;
embaixo, versões de teste (`Beta`, `Dev`) e programas parecidos de outros fabricantes.
Nada é escondido — tudo o que o WinGet encontrou continua na lista.

Cada item mostra o nome, o **editor** e o pacote, para você distinguir o programa
oficial de um parecido. Você escolhe pelo número, confere os dados na tela e confirma
com `[1]`. Os números são só dos aplicativos: para procurar outra coisa tecle `P`, e
para voltar tecle `V` — em maiúscula ou minúscula, sempre as mesmas teclas, inclusive
quando a pesquisa não encontra nada.

Se aparecerem muitos resultados, a tela mostra os mais relevantes e avisa quantos
foram encontrados, para você escrever um nome mais específico.

Se o aplicativo **já estiver instalado**, a Central avisa e não instala nada — para
atualizar o que já existe, use a opção `3`. Se algo der errado, a mensagem explica o
motivo em português e informa que nada mais foi alterado. Precisa de internet.

> A instalação usa sempre o pacote oficial confirmado pelo WinGet. O que você digita
> serve apenas para procurar: nada do texto vira comando.

#### `2` › `3` Atualizar aplicativos

**O que é:** atualiza os programas instalados para as versões mais novas.

**Quando usar:** de vez em quando, para manter tudo em dia.

**O que esperar:** precisa de internet. Programas abertos podem falhar ao atualizar —
feche o que puder antes. É comum aparecerem alguns avisos amarelos.

---

### `3` Rede, Internet e Conectividade

**Quando usar:** internet não funciona, sites não abrem, Wi-Fi conecta mas não navega.

**Opções que só mostram informação (seguras):**

- `4` Diagnóstico de Adaptadores — mostra o estado das placas de rede
- `5` Teste de Conectividade — testa se a internet responde e se os nomes de sites são resolvidos
- `6` Configuração de Proxy — mostra se há proxy configurado
- `7` Diagnóstico Wi-Fi — sinal, canal e redes salvas

**Opções que consertam:**

- `1` **Reset Completo** — devolve toda a configuração de rede ao padrão. É a que
  mais resolve. **Reinicie depois.**
- `2` **Restaurar Arquivo Hosts** — se alguns sites específicos não abrem, pode ser
  que estejam bloqueados neste arquivo. Isso o limpa.
- `3` **Restaurar Firewall** — volta o firewall ao padrão. Alguns programas vão
  pedir autorização de novo.

---

### `4` Otimização, Limpeza e Privacidade

**Quando usar:** disco cheio, computador lento.

**Comece sempre por:**

- `4` **Simular Limpeza** — mostra quanto espaço seria liberado, **sem apagar nada**.
  Assim você decide com informação.

**Para liberar espaço:**

- `1` **Limpeza Customizada** — apaga temporários, caches e arquivos de atualização.
  Vai perguntar se deve apagar também os registros de eventos: **responda N**, eles
  ajudam a diagnosticar problemas futuros.
- `5` **Limpeza de Navegadores** — limpa o cache dos navegadores. **Suas senhas e
  favoritos não são apagados.** Feche os navegadores antes.

**Para desempenho:**

- `6` **Análise de Desempenho** — só mostra: o que abre junto com o Windows, o que
  consome memória, qual plano de energia está ativo.
- `3` **Desempenho Máximo** — prioriza velocidade sobre economia de energia. Em
  notebook, gasta mais bateria.
- `8` **Restaurar Equilibrado** — desfaz a opção acima.

**Para privacidade:**

- `2` **Desativar Telemetria** — reduz o envio de dados de uso à Microsoft.
- `7` **Restaurar Telemetria** — desfaz.

> Repare: tudo neste menu que altera configuração tem uma opção que desfaz.

---

### `5` Reparo do Sistema e Windows Update

**Quando usar:** erros estranhos no Windows, atualizações que não instalam,
impressora que não imprime, barra de tarefas travada.

- `1` **Reparo Profundo** — verifica e conserta os arquivos do próprio Windows.
  De 15 a 45 minutos. É a opção certa para problemas inexplicáveis.
- `2` **Destravar Windows Update** — quando as atualizações travam ou dão erro.
- `3` **Destravar Fila de Impressão** — documento preso na fila que não sai nem
  cancela.
- `4` **Reiniciar Explorer** — barra de tarefas ou ícones travados. A tela pisca e
  volta ao normal em segundos.
- `9` **Reconstruir Cache de Ícones** — ícones errados ou em branco.
- `5` **Agendar Verificação de Disco** — a verificação acontece na próxima vez que
  você ligar o computador, antes da tela de senha. Pode demorar bastante.

**Só informação:** `6` Status do Windows Update, `7` Procurar Atualizações,
`8` Limpar Cache de Atualizações.

---

### `6` Contas, Permissões e Segurança

> **Cuidado.** Este é o menu mais sensível. Em computador de empresa, converse com a
> TI antes.

**Seguro, só mostra informação:**

- `5` **Postura de Segurança** — Secure Boot, TPM, integridade de memória, UAC e
  mais. Excelente para entender o nível de proteção da máquina.
- `6` **Status do Defender** — se o antivírus está ativo e atualizado.
- `8` **Exclusões e Histórico de Ameaças** — o que o antivírus já encontrou e quais
  pastas ele foi mandado ignorar.
- `9` **Auditoria de Contas** — quem tem conta na máquina e tentativas de logon que falharam.

**Altera o sistema:**

- `3` **Forçar Varredura Defender** — atualiza o antivírus e faz uma varredura rápida.
- `7` **Varredura Completa** — de 1 a 4 horas. Pede confirmação.
- `2` **Gerenciar Contas Locais** — permite redefinir senha de conta. Remover uma
  senha exige digitar a palavra `REMOVER` por extenso, de propósito.
- `1` **Resetar GPO Local** — apaga as políticas locais. Em máquina de empresa, isso
  pode desfazer configurações obrigatórias.
- `4` **Assumir Controle de Pasta** — para acessar pastas com "acesso negado". A
  ferramenta recusa fazer isso em pastas críticas do Windows.

---

### `7` Discos, Drivers e Hardware

**Este menu é quase todo seguro** — praticamente só mostra informação.

- `1` **Saúde Física dos Discos** — a leitura mais importante da ferramenta. Se o
  disco indicar problema, **faça backup dos seus arquivos hoje**.
- `2` **Relatório de Bateria** — só para notebook. Compara a capacidade atual com a
  de fábrica: mostra o desgaste real.
- `3` **Status BitLocker** — se o disco está criptografado.
- `6` **Inventário Completo** — tudo sobre o hardware: processador, memória, placa
  de vídeo, monitores, portas USB.
- `7` **Contadores de Desgaste** — horas ligado, dados escritos, setores com defeito.
- `8` **Volumes e Espaço** — quanto resta em cada disco.
- `9` **Drivers com Problema** — dispositivos que não estão funcionando bem.
- `4` **Backup de Drivers** — salva todos os drivers em uma pasta. **Faça isso antes
  de formatar.**

---

### `8` Diagnóstico e Relatórios

**Menu totalmente seguro. Nada aqui altera o computador.**

- `1` **Auditoria Completa** — o retrato completo da máquina, em quatro formatos.
  O relatório visual abre sozinho no navegador ao terminar. **É este que você envia
  para o suporte técnico.**
- `2` **Auditoria Rápida** — versão resumida, em menos de um minuto.
- `3` **Consolidar Relatório** — junta tudo que foi feito nesta sessão.
- `4` e `5` **Eventos Críticos** — erros que o Windows registrou nos últimos 7 ou 30 dias.
- `6` **Aplicativos Instalados** — lista completa de programas.
- `7` **Licenciamento** — se o Windows está ativado.
- `9` **Abrir Último Relatório** — reabre o relatório mais recente.

---

### `9` Ambiente de Execução

A tela "Sobre" da ferramenta. Mostra a versão, a autoria, qual mecanismo está em uso
e o que a ferramenta encontrou disponível no seu Windows (`1` = disponível,
`0` = indisponível).

Consulte esta tela primeiro quando algo não funcionar: ela explica o porquê.

---

## Desbloat: tirar o que veio de fábrica

Seu computador provavelmente veio com programas que você nunca pediu. Jogos, testes de
antivírus, aplicativos do fabricante. Alguns ficam rodando em segundo plano mesmo sem
você abrir.

A opção `[4]` e depois `[9]` cuida disso.

### Comece simulando

A primeira opção do submenu, `[1]`, mostra uma lista do que seria removido, com o
motivo de cada item. **Ela não apaga nada.** Leia com calma antes de decidir.

### Escolha o nível

| Se você | Escolha | Tecla |
|---|---|:---:|
| Não tem certeza, ou é seu primeiro uso | Seguro | `[2]` |
| Sabe que não usa Xbox, Fotos, Câmera nem o Email do Windows | Moderado | `[3]` |
| É administrador e sabe o que está desligando | Avançado | `[4]` |

O nível Seguro tira apenas o que é propaganda ou foi abandonado pela Microsoft. Nada
que o Windows precise para funcionar entra na lista, em nenhum nível.

### O que esperar

A tela vai listando cada item e o que aconteceu com ele. Palavras que você vai ver:

| Palavra | Significa |
|---|---|
| `Aplicado` | Foi alterado |
| `Simulado` | Só mostrou, não mexeu |
| `JaAplicado` | Já estava assim, nada a fazer |
| `Protegido` | Está na lista do que nunca pode ser tocado |
| `Falhou` | Não deu certo. O motivo aparece ao lado |

Ao final, reinicie o computador.

### Se você removeu algo que usa

Vá em `[4]` › `[9]` › `[9]` › `[4]` para desfazer. Serviços e configurações voltam
sozinhos, exatamente como estavam.

**Aplicativos são a exceção.** O Windows não guarda o programa depois de removê-lo,
então você precisa baixá-lo de novo pela Microsoft Store. O nome exato de cada um
aparece no relatório. É por isso que a simulação existe.

### A lista completa

Cada nível e cada item estão detalhados no
[Módulo de Desbloat](DESBLOAT.md).

---

## Os relatórios

Ao usar o menu `8`, são criados quatro arquivos na pasta `COMPARTDISK_Relatorios`:

| Arquivo | Para quê |
|---|---|
| `.html` | **Para você ler.** Abre no navegador, colorido e organizado |
| `.txt` | Texto simples, fácil de anexar em e-mail |
| `.csv` | Para abrir no Excel |
| `.json` | Para sistemas automatizados |

### Lendo o relatório HTML

No topo há três números: **críticos**, **em atenção** e **conformes**. Esse é o
resumo — se os críticos estão em zero, a máquina está bem.

Cada linha traz um marcador:

| Marcador | Significa |
|---|---|
| `[ OK ]` | Está certo |
| `[WARN]` | Merece atenção |
| `[CRIT]` | Precisa de providência |

Clique nos títulos das seções para abrir e fechar.

---

## Perguntas rápidas

**Posso fechar a janela no meio de uma operação?**
Evite. Espere terminar. Se estiver realmente travado, feche — mas anote o que estava
fazendo e verifique o log depois.

**A tela ficou parada. Travou?**
Provavelmente não. Reparo Profundo e varreduras ficam minutos sem mostrar nada.

**Preciso reiniciar depois?**
Depois de reparos de rede, do sistema ou do Windows Update, sim.

**Isso vai apagar meus arquivos?**
Não. As limpezas mexem em arquivos temporários e caches. Seus documentos, fotos,
senhas e favoritos não são tocados.

**Funciona sem internet?**
Sim, exceto a opção `2` (atualizar e instalar aplicativos) e a busca por atualizações
do Windows.

Mais perguntas em [FAQ](FAQ.md). Problemas em
[Solução de Problemas](SOLUCAO-DE-PROBLEMAS.md).

---

[Voltar ao índice](../README.md) · Próximo: [Menus](MENUS.md)
