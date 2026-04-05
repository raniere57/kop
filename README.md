# Kop

Kop e um gerenciador de area de transferencia nativo para macOS, feito em SwiftUI + AppKit, focado em abrir rapido pela barra de menu com `Option + Space`.

## Requisitos

- macOS 13 Ventura ou superior
- Xcode 15 ou superior

## Build

1. Abra [Kop.xcodeproj](/Users/raniere/Dev/kop/Kop.xcodeproj) no Xcode.
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
- DMG aberto automaticamente no Finder
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
- Accessibility: necessaria apenas para a acao "Copiar e Colar", que envia `Cmd + V`

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
