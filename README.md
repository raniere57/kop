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

O DMG gerado inclui:

- `Kop.app`
- atalho para `/Applications` para instalacao por drag and drop

## Instalar localmente

Se quiser testar o app aparecendo no Spotlight e no Launchpad, ele precisa estar em `/Applications`.
Depois de gerar o build Release em `dist/Kop.app`, rode:

```sh
chmod +x Scripts/install_app.sh
./Scripts/install_app.sh
```

Isso copia o app para `/Applications/Kop.app`, registra no Launch Services e dispara reimportacao no Spotlight.

## Permissoes

- Clipboard: acesso via `NSPasteboard`
- Hotkey global: registrado com Carbon `RegisterEventHotKey`
- Accessibility: necessaria apenas para a acao "Copiar e Colar", que envia `Cmd + V`

## Distribuicao fora da App Store

- O target usa `LSUIElement = YES`, entao o app roda sem icone no Dock.
- O sandbox deve permanecer desativado para que o comportamento global do clipboard funcione sem restricoes.
- Assine o app com um certificado `Developer ID Application`.
- Gere um `.app` assinado e, se for distribuir para terceiros, notarize o binario antes de montar o `.dmg`.
- Se quiser ativar "Iniciar com o sistema", confira o comportamento do `SMAppService.mainApp` no perfil de assinatura usado.

## Estrutura

- `Kop/App`: bootstrap do app e `AppDelegate`
- `Kop/Core`: monitoramento, persistencia, preferencias e hotkey
- `Kop/UI`: painel flutuante, lista, preview e preferencias
- `Kop/Helpers`: thumbnails, icones, menu bar e automacao de paste
