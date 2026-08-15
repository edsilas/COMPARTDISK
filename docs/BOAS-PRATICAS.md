# Boas Práticas de Utilização

**COMPARTDISK 1.4.2** · Desenvolvido por Edsilas

Como usar a ferramenta com segurança e obter o melhor resultado.

---

## As cinco regras

### 1. Observe antes de agir

Rode uma auditoria (menu `8` → `2`) antes de qualquer reparo. Você ganha um retrato do
"antes", útil para comparar depois e para saber se o reparo era mesmo necessário.

### 2. Prefira simular

A opção **Simular Limpeza** (menu `4` → `4`) mostra quanto espaço cada categoria
liberaria, sem apagar nada. Decida com informação, não no escuro.

### 3. Um problema de cada vez

Resista à tentação de executar tudo. Se você roda cinco reparos e o problema some,
não saberá qual resolveu — nem o que fazer se voltar.

### 4. Reinicie quando pedido

Reparos de rede, de sistema e do Windows Update só passam a valer depois de
reiniciar. Sem isso, você pode concluir que "não funcionou" quando na verdade
funcionou.

### 5. Guarde o relatório

Antes de mudanças grandes, gere a auditoria completa (menu `8` → `1`) e guarde o
arquivo HTML. É a sua referência do estado anterior.

---

## Ordem recomendada de diagnóstico

Do menos ao mais invasivo:

```
1. Menu 9        -> o que a ferramenta detectou no sistema
2. Menu 8 -> 2   -> auditoria rápida
3. Menu 8 -> 1   -> auditoria completa (relatório HTML)
4. Menu 7 -> 1   -> saúde física dos discos
5. Menu 8 -> 4   -> eventos críticos recentes
   ------------------------------------------------- fim da fase de leitura
6. Reparos específicos, conforme o que foi encontrado
```

Só passe da linha depois de entender o problema.

---

## Antes de operações que alteram o sistema

| Antes de | Faça |
|---|---|
| Qualquer reparo grande | Auditoria completa, e guarde o HTML |
| Limpeza | Simule primeiro (menu `4` → `4`) |
| Limpeza de navegadores | Feche os navegadores |
| Atualizar programas | Feche os programas que puder |
| Resetar GPO | Confirme com a TI, se for máquina da empresa |
| Formatar o computador | Backup de drivers (menu `7` → `4`) |
| Qualquer coisa, em máquina crítica | Crie um ponto de restauração do Windows |

---

## Em ambiente corporativo

- **Converse com a TI antes de usar o menu `6`.** Resetar diretivas de grupo pode
  desfazer configurações obrigatórias da organização.
- **Não desative a telemetria em massa** sem verificar a política interna: algumas
  organizações dependem desses dados para inventário e conformidade.
- **Prefira o modo desassistido** (`/audit`) para coleta em várias máquinas. Veja o
  [Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md).
- **Centralize os relatórios** definindo `COMPARTDISK_LOGDIR` para um compartilhamento
  de rede.

---

## Antes de um desbloat

O desbloat altera o que está instalado e o que roda, não apenas arquivos descartáveis.
Trate-o com o cuidado que essa diferença pede.

| Prática | Por quê |
|---|---|
| Simule primeiro, sempre | A opção `[1]` do submenu lista tudo sem tocar em nada. É a única forma de saber o que sairia |
| Registre o estado antes | `[9]` › `[2]` cria o retrato de tudo que o catálogo alcança |
| Confirme a Proteção do Sistema | Sem ela, a rotina completa se recusa a rodar. E ela está certa em recusar |
| Comece pelo nível Seguro | Rode, use a máquina por alguns dias, e só então avalie subir de nível |
| Não use o Avançado em máquina de terceiros | Ele desliga a busca do menu Iniciar. Quem usa a máquina no dia a dia vai estranhar |
| Reinicie ao final | Alterações de serviço e de componente só se consolidam depois |

**A regra que vale mais que todas.** Aplicativos removidos não voltam sozinhos. Se
existe dúvida sobre um item, exclua-o da execução em vez de removê-lo e torcer.

---

## Frequência de uso

Não há necessidade de uso periódico. A ferramenta é para quando há um problema.

Uma exceção vale a pena: **verifique a saúde dos discos** (menu `7` → `1`) a cada
poucos meses. Disco em falha dá sinais antes de morrer, e essa é a única leitura que
pode salvar seus dados.

---

## O que evitar

**Não execute de dentro do arquivo `.zip`.** Extraia primeiro.

**Não feche a janela no meio de um reparo.** Especialmente durante SFC, DISM ou
verificação de disco. Aguarde.

**Não use o menu `6` em máquina da empresa sem autorização.**

**Não conte com a limpeza para liberar espaço permanentemente.** Caches se
reconstroem. Se o disco vive cheio, o problema é outro.

**Não apague os registros de eventos** ao usar a Limpeza Customizada, a menos que
tenha um motivo. Responda `N` à pergunta: esses registros são o que permite
diagnosticar problemas depois.

---

## Interpretando os resultados

### No relatório HTML

| Marcador | O que fazer |
|---|---|
| `[CRIT]` | Precisa de providência. Leia a recomendação ao lado |
| `[WARN]` | Vale acompanhar. Nem sempre exige ação imediata |
| `[ OK ]` | Nada a fazer |
| `[INFO]` | Apenas contexto |

### Sinais que merecem ação imediata

- Disco físico com status diferente de saudável → **backup hoje**
- Contadores de setores realocados crescendo → **disco em degradação**
- Defender desativado ou desatualizado → **verifique a proteção**
- Bateria com capacidade muito abaixo da de fábrica → **desgaste natural, considere troca**
- Eventos críticos repetindo o mesmo identificador → **problema recorrente, investigue**

---

[Voltar ao índice](../README.md) · Próximo: [Política de Atualização](ATUALIZACAO.md)
