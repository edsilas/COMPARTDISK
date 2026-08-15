# Guia de Instalação

**COMPARTDISK 1.4.1** · Desenvolvido por Edsilas

O COMPARTDISK **não tem instalador**. Você baixa, descompacta e executa. Nada é
gravado permanentemente no sistema, e para remover basta apagar a pasta.

---

> [!TIP]
> Para uso pontual, existe um método sem download: um único comando no PowerShell
> executa a versão mais recente. Consulte o
> [Guia de Execução Remota](EXECUCAO-REMOTA.md).

## Passo 1 — Baixar

Acesse https://github.com/edsilas/compartdisk e clique no botão verde **Code**,
depois em **Download ZIP**.

Se preferir — e é o método recomendado — use a página oficial de *Releases* e baixe o
pacote da versão 1.4.1:

**https://github.com/edsilas/COMPARTDISK/releases**

## Passo 2 — Descompactar

1. Localize o arquivo `.zip` baixado (normalmente na pasta **Downloads**).
2. Clique com o botão direito e escolha **Extrair tudo**.
3. Escolha uma pasta fácil de achar, por exemplo `C:\COMPARTDISK`.

> **Importante:** não execute o programa de dentro do `.zip`. O Windows abre o
> conteúdo em uma pasta temporária somente-leitura, e a ferramenta não conseguirá
> gravar os relatórios.

## Passo 3 — Conferir o conteúdo

Depois de extrair, a pasta deve ter esta aparência:

```
COMPARTDISK\
├── Launcher.bat        <- é este que você executa
├── README.md
├── CHANGELOG.md
├── LICENSE
├── Modules\            <- 19 arquivos .ps1
└── docs\               <- a documentação
```

Se a pasta `Modules` estiver faltando, a ferramenta ainda funciona, mas com
diagnóstico reduzido. Descompacte novamente.

## Passo 4 — Executar

1. Clique com o botão direito em **`Launcher.bat`**.
2. Escolha **Executar como administrador**.
3. O Windows exibirá a janela azul do Controle de Conta de Usuário. Clique em **Sim**.

Se você abrir com um clique duplo simples, a ferramenta pede a elevação sozinha —
o resultado é o mesmo.

---

## Avisos que podem aparecer

### "O Windows protegeu o computador"

É a tela azul do **SmartScreen**. Aparece porque o arquivo veio da internet e não tem
assinatura digital paga.

1. Clique em **Mais informações**.
2. Clique em **Executar assim mesmo**.

Alternativa, para evitar o aviso de vez: clique com o botão direito no `.zip`
**antes de extrair**, escolha **Propriedades**, marque **Desbloquear** e clique em
**OK**. Depois extraia normalmente.

### O antivírus bloqueou

Alguns antivírus desconfiam de qualquer script que mexa em rede e registro — é o
comportamento esperado deles. O código é aberto e legível: você pode abrir qualquer
arquivo no Bloco de Notas e conferir o que ele faz.

Se confiar, adicione a pasta às exclusões do antivírus.

### Nada acontece ao clicar

Consulte o [Guia de Solução de Problemas](SOLUCAO-DE-PROBLEMAS.md).

---

## Instalando em várias máquinas

Para uso em parque de computadores, consulte o
[Manual do Administrador](MANUAL-DO-ADMINISTRADOR.md). Em resumo:

- A pasta pode ficar em um compartilhamento de rede e ser executada de lá.
- Não é necessário instalar nada nas estações.
- Há parâmetros de linha de comando para execução sem intervenção do usuário.

---

## Desinstalar

Apague a pasta. É tudo.

Se quiser remover também os arquivos gerados, procure e apague:

| Arquivo | Onde costuma estar |
|---|---|
| `Relatorio_Manutencao.txt` | Na pasta do programa ou na Área de Trabalho |
| `COMPARTDISK_Relatorios\` | Na mesma pasta do arquivo acima |
| `COMPARTDISK_Bootstrap.log` | Na pasta temporária do Windows |

A ferramenta não cria serviços, não altera a inicialização do Windows e não deixa
nada em execução depois de fechada.

---

[Voltar ao índice](../README.md) · Próximo: [Guia de Configuração](CONFIGURACAO.md)
