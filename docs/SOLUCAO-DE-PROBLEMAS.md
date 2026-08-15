# Guia de Solução de Problemas

**COMPARTDISK 1.4.2** · Desenvolvido por Edsilas

Problemas organizados por sintoma. Comece pelo que você está vendo.

---

## A janela abre e fecha imediatamente

### Onde está a resposta

A ferramenta grava um registro de inicialização em:

```
%TEMP%\COMPARTDISK_Bootstrap.log
```

Para abrir: aperte `Windows + R`, digite `%TEMP%` e pressione Enter. Localize o
arquivo e abra com o Bloco de Notas.

**A última linha do arquivo diz exatamente onde a partida parou.**

### O que cada estágio significa

| Estágio | Parou aqui porque |
|---|---|
| 01 | Problema no próprio interpretador de comandos |
| 02 | Console sem suporte a cores — não impede o funcionamento |
| 03 | Falha ao preparar a interface |
| 04 | Reentrada após o UAC |
| 05 | Detecção de privilégio administrativo |
| 06 | Falha ao solicitar elevação (`06b` = tentando PowerShell, `06c` = nenhum método funcionou) |
| 07 | Instância elevada foi iniciada; esta janela encerrou normalmente |
| 08 | Privilégio administrativo confirmado |
| 09 | Nenhuma pasta aceitou gravação |
| 10 | Seleção do motor de execução |
| 11 | Verificação do ambiente |
| 12 | Partida concluída — o problema é posterior |

Se a última linha for **`ENCERRAMENTO NORMAL`**, a ferramenta fechou corretamente.

### Causas mais comuns

**Executando de dentro do `.zip`.** Extraia para uma pasta de verdade antes.

**Nenhuma pasta aceita gravação (estágio 09).** Copie a pasta para `C:\COMPARTDISK`
e tente de novo.

**Command Extensions desativadas (estágio 01).** Abra o Prompt de Comando e execute:

```bat
cmd.exe /E:ON /C "C:\COMPARTDISK\Launcher.bat"
```

**Windows Script Host bloqueado (estágio 06c).** A elevação automática não funciona.
Clique com o botão direito no `Launcher.bat` e escolha **Executar como administrador**
manualmente.

---

## Aparece "O Windows protegeu o computador"

É o SmartScreen, e é esperado: o arquivo veio da internet e não tem assinatura
digital paga.

1. Clique em **Mais informações**
2. Clique em **Executar assim mesmo**

Para evitar de vez: antes de extrair, clique com o botão direito no `.zip` →
**Propriedades** → marque **Desbloquear** → **OK**.

---

## O antivírus bloqueou ou removeu arquivos

Falso positivo. A ferramenta altera rede, registro e serviços — exatamente o padrão
de comportamento que antivírus monitoram.

O código é aberto: abra qualquer arquivo no Bloco de Notas e confira. Se confiar,
adicione a pasta às exclusões do antivírus e extraia novamente.

---

## Diz "Motor: Batch"

**Não é um erro.** Significa que o PowerShell não está disponível ou foi bloqueado.

Todas as funções continuam acessíveis por rotinas Batch equivalentes. O que muda é a
profundidade do diagnóstico: os relatórios em HTML, JSON e CSV não são gerados, e
algumas leituras ficam mais simples.

Causas possíveis: política de execução restritiva, AppLocker, WDAC, ou PowerShell
removido da imagem do Windows.

Para confirmar, abra o menu `9` — ele mostra o que foi detectado.

---

## Uma opção diz "recurso não suportado"

Comportamento correto. Seu hardware ou edição do Windows não tem aquele recurso.

| Recurso | Requer |
|---|---|
| Relatório de bateria | Notebook |
| BitLocker | Edição Pro, Education ou Enterprise |
| Diretivas de grupo locais | Edição Pro ou superior |
| TPM / Secure Boot | Suporte no equipamento |
| Winget | Windows 10 versão 1809 ou superior, com App Installer |

---

## O log está vazio ou incompleto

Verifique, no rodapé do menu principal, qual caminho está sendo usado. Se a pasta for
somente-leitura, a ferramenta tenta a Área de Trabalho e depois a pasta temporária.

Se ainda assim falhar, defina o destino manualmente:

```bat
set "COMPARTDISK_LOGDIR=C:\Temp\"
Launcher.bat
```

---

## Uma operação parece travada

Compare com os tempos normais:

| Operação | Tempo típico |
|---|---|
| Reparo Profundo | 15 a 45 min |
| Varredura Completa do Defender | 1 a 4 h |
| Reparo Geral Automático | 20 a 60 min |
| Auditoria Completa | 1 a 5 min |
| Limpeza Profunda | 2 a 15 min |

É normal a tela ficar parada por minutos durante essas operações.

Se passar bastante do tempo esperado, abra o Gerenciador de Tarefas e veja se há
atividade de disco ou processador. Havendo, ainda está trabalhando.

---

## A busca do menu Iniciar parou de funcionar

Sintoma de quem executou o desbloat no nível Avançado: digitar o nome de um programa no
menu Iniciar não encontra mais nada. Abrir pela lista continua funcionando.

**Causa.** O serviço `WSearch`, responsável pela indexação, foi desativado. É o
comportamento documentado do nível Avançado.

**Solução.** Use `[4]` › `[9]` › `[9]` › `[4]` para reverter. Ou reative manualmente:

```bat
sc config WSearch start= delayed-auto
net start WSearch
```

A reindexação leva algum tempo depois de religado.

---

## A limpeza de componentes falhou

**Causa mais comum.** Reinício pendente. O DISM não consegue compactar o armazenamento
de componentes enquanto há atualizações aguardando reinicialização.

**Solução.** Reinicie e execute novamente `[4]` › `[9]` › `[8]`.

Se persistir, rode antes o reparo profundo em `[5]` › `[1]`: uma imagem com
inconsistências impede a limpeza.

---

## Removi um aplicativo que eu usava

Serviços, tarefas e ajustes voltam sozinhos por `[4]` › `[9]` › `[9]` › `[4]`.

Aplicativos não. O Windows não guarda o pacote no disco depois da remoção. Abra a
Microsoft Store e reinstale — o nome exato está no relatório da sessão e no manifesto em
`COMPARTDISK_Restauracao`.

---

## O ponto de restauração não pôde ser criado

**Se a mensagem cita 1440 minutos:** já existe um ponto criado nas últimas 24 horas. O
módulo reconhece isso e prossegue, tratando o ponto recente como válido. Não é erro.

**Se a mensagem é outra:** a Proteção do Sistema provavelmente está desligada. Ative em
Sistema › Proteção do Sistema, selecione o disco do Windows e clique em Configurar.

A rotina completa se recusa a rodar sem ponto de restauração, e essa recusa é
intencional.

---

## O reset de rede não resolveu

**Reinicie o computador.** Boa parte das alterações de rede só passa a valer depois
de reiniciar.

Se persistir, verifique nesta ordem:

1. Menu `3` → `4` — a placa de rede aparece e está ativa?
2. Menu `3` → `5` — o teste de conectividade chega a algum lugar?
3. Menu `3` → `6` — há um proxy configurado que não deveria estar?
4. Menu `3` → `2` — o arquivo `hosts` foi restaurado?
5. Menu `7` → `9` — o driver da placa de rede está com problema?

---

## O Windows Update continua falhando

1. Menu `5` → `2` — Destravar Windows Update
2. **Reinicie**
3. Menu `5` → `7` — Procurar Atualizações

Se ainda falhar, execute o Reparo Profundo (menu `5` → `1`): arquivos de sistema
corrompidos são causa frequente de falha em atualizações.

---

## Depois de usar, algo parou de funcionar

Consulte o `Relatorio_Manutencao.txt` para ver exatamente o que foi executado.

Como desfazer:

| Se você usou | Para desfazer |
|---|---|
| Desativar Telemetria | Menu `4` → `7` |
| Desempenho Máximo | Menu `4` → `8` |
| Restaurar Firewall | Restaure o arquivo `Firewall_Backup.wfw` gerado |
| Restaurar Arquivo Hosts | Restaure a cópia gravada ao lado do original |
| Resetar GPO Local | Restaure a pasta de backup criada antes |

Limpezas de arquivo **não podem ser desfeitas**. É por isso que existe a opção de
simulação (menu `4` → `4`).

---

## Ainda não resolveu

Reúna estas informações antes de pedir ajuda:

1. O relatório HTML — menu `8` → `1`
2. O arquivo `Relatorio_Manutencao.txt`
3. O arquivo `%TEMP%\COMPARTDISK_Bootstrap.log`
4. O que aparece no menu `9`

Abra uma *issue* em https://github.com/edsilas/compartdisk/issues descrevendo o que
tentou fazer e o que aconteceu.

---

[Voltar ao índice](../README.md) · Próximo: [Boas Práticas](BOAS-PRATICAS.md)
