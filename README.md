# Kop

Kop e um gerenciador de area de transferencia nativo para macOS, feito em SwiftUI + AppKit, focado em abrir rapido pela barra de menu com `Option + Space`.

## Atalhos do painel

| Atalho | Acao |
| --- | --- |
| `Option + Space` | abrir/fechar o painel (configuravel) |
| `↑` / `↓` | navegar pela lista |
| `Return` | colar (ou apenas copiar, conforme preferencia) |
| `Shift + Return` | colar como texto puro |
| `Cmd + 1` … `Cmd + 9` | usar direto o item da posicao |
| `Cmd + D` | favoritar / desfavoritar |
| `Cmd + Y` | visualizar |
| `Cmd + Delete` | apagar item (com a busca vazia; favoritos nao sao apagados pelo atalho) |
| `Esc` | fechar |

## Instalar

1. Baixe o `Kop-<versao>.dmg` em [Releases](https://github.com/raniere57/kop/releases/latest).
2. Arraste `Kop.app` para `Applications`.
3. O app nao e notarizado. Na primeira vez, libere a quarentena:

```sh
xattr -dr com.apple.quarantine /Applications/Kop.app
```

## Requisitos

- macOS 13 Ventura ou superior
- Xcode 15 ou superior (apenas para compilar)

## Build

1. Abra `Kop.xcodeproj` no Xcode.
2. Selecione o target `Kop`.
3. Rode o app com `Cmd + R`.

Via terminal:

```sh
xcodebuild -project Kop.xcodeproj -scheme Kop -configuration Debug build
```

## Gerar DMG

Para criar um `.dmg` instalavel com o app:

```sh
chmod +x Scripts/create_dmg.sh
./Scripts/create_dmg.sh
```

Saida esperada:

- App Release em `.derived/Build/Products/Release/Kop.app`
- DMG final em `dist/Kop.dmg`
- DMG aberto automaticamente no Finder (quando rodado em um terminal interativo)
- Janela pronta para arrastar `Kop.app` para `Applications`

O DMG gerado inclui:

- `Kop.app`
- atalho para `/Applications` para instalacao por drag and drop

## Instalar localmente

Para o Kop aparecer no Spotlight, ele precisa estar instalado em `/Applications`.
So o build em `.derived` ou `dist/` nao entra no catalogo normal de apps do macOS.

O Kop e um menu bar app. Por design do macOS, apps com `LSUIElement = true` nao aparecem no Launchpad. Isso e esperado.

Fluxo recomendado:

1. Rode `./Scripts/create_dmg.sh`
2. Quando o DMG abrir, arraste `Kop.app` para `Applications`
3. Rode `lsregister -f /Applications/Kop.app`
4. Abra o app uma vez

Se quiser automatizar a copia para `/Applications` em vez de arrastar manualmente, depois de gerar o build Release em `dist/Kop.app`, rode:

```sh
chmod +x Scripts/install_app.sh
./Scripts/install_app.sh
```

Isso copia o app para `/Applications/Kop.app`, remove quarentena, registra no Launch Services, reimporta no Spotlight, reinicia o Dock e abre o Kop uma vez.

## Permissoes

- Clipboard: acesso via `NSPasteboard`
- Hotkey global: registrado com Carbon `RegisterEventHotKey`
- Accessibility: necessaria apenas para colar automaticamente (envia `Cmd + V`). Sem ela o item so e copiado, e o Kop avisa uma vez com um atalho para os Ajustes.

Conteudo marcado como confidencial (`org.nspasteboard.ConcealedType` e afins, usado por gerenciadores de senha) nunca e gravado no historico.

## Armazenamento

Tudo que o Kop grava fica em `~/Library/Application Support/Kop`:

- `history.sqlite` (WAL) com o historico
- `Images/` com PNGs gerados para itens de imagem
- `Thumbnails/` com as miniaturas da lista

Arquivos gerados sao apagados junto com o item do historico. Arquivos que pertencem ao usuario nunca sao removidos.

## Teste rapido

Checagem da camada de dados (dedupe, busca, limite, limpeza de arquivos):

```sh
./Scripts/selfcheck.sh
```

## Distribuicao fora da App Store

- O Kop e distribuido como menu bar app nativo.
- Ele aparece no Spotlight quando instalado em `/Applications`, mas nao aparece no Launchpad por causa de `LSUIElement = true`.
- O sandbox deve permanecer desativado para que o comportamento global do clipboard funcione sem restricoes.
- Assine o app com um certificado `Developer ID Application`.
- Gere um `.app` assinado e, se for distribuir para terceiros, notarize o binario antes de montar o `.dmg`.
- Se quiser ativar "Iniciar com o sistema", confira o comportamento do `SMAppService.mainApp` no perfil de assinatura usado.

## Estrutura

- `Kop/App`: bootstrap do app e `AppDelegate`
- `Kop/Core`: monitoramento, persistencia, preferencias e hotkey
- `Kop/UI`: painel flutuante, lista, preview e preferencias
- `Kop/Helpers`: thumbnails, icones, menu bar e automacao de paste
- `Scripts/selfcheck`: checagem executavel da persistencia
