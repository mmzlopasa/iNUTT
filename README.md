# iNUTT

iOS aplikacija za pregled slika, GIF-ova i videa s do 50 stranica koje dodaš u postavkama. Sadržaj se parsira nativno i prikazuje kao aplikacija, bez vidljivog preglednika.

Developer: [SCYDE](https://scyde.dev)

## Instalacija (Feather)

Svaki push gradi nepotpisani `inutt.ipa` (GitHub Actions, `Build IPA`) i objavljuje ga kao release `nightly`:

https://github.com/mmzlopasa/iNUTT/releases/download/nightly/inutt.ipa

Feather ga potpisuje tvojim certifikatom pri instalaciji.

## Build lokalno

```sh
brew install xcodegen
xcodegen generate
open iNUTT.xcodeproj
```

Ikona se generira s `python3 tools/make_icon.py iNUTT/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png`.
