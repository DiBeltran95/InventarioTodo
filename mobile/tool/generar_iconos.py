"""Genera los iconos de iOS y Android a partir de assets/icono/icono_fuente.png.

Uso (desde mobile/):  python tool/generar_iconos.py

Por qué un script y no el icono tal cual: la imagen fuente ya trae su propio
cuadrado redondeado con margen transparente alrededor. iOS y Android recortan
el icono con su propia máscara, así que usada sin tratar saldría un cuadrado
redondeado dentro de otro, con esquinas blancas. Además iOS rechaza iconos con
transparencia (el de 1024 de la App Store debe ser opaco).

Pasos: se recorta al cuadrado oscuro, se rellenan sus esquinas redondeadas con
el color del borde contiguo (queda a sangre completa, sin alfa) y de ahí salen
todos los tamaños.
"""
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

RAIZ = Path(__file__).resolve().parent.parent
FUENTE = RAIZ / 'assets/icono/icono_fuente.png'
IOS = RAIZ / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
RES = RAIZ / 'android/app/src/main/res'

# Azul de respaldo para rincones de esquina sin fondo seguro cercano.
FONDO = (2, 36, 90)


def cuadro_oscuro(im):
    """Caja del cuadrado redondeado de la fuente."""
    px = im.load()
    w, h = im.size
    xs, ys = [], []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b, a = px[x, y]
            if a > 200 and r < 40 and g < 60 and b < 120:
                xs.append(x)
                ys.append(y)
    return min(xs), min(ys), max(xs) + 1, max(ys) + 1


def a_sangre(im):
    """Lleva el cuadrado redondeado a sangre completa, sin alfa.

    Las esquinas redondeadas y el borde antialias (azul mezclado con blanco)
    se sustituyen por el fondo más cercano que sea opaco del todo. Así el
    sistema aplica su máscara sobre fondo limpio, sin filo claro alrededor.
    """
    w, h = im.size
    alfa = im.split()[3].point(lambda a: 255 if a >= 255 else 0)
    # «Seguro» = opaco y lejos de cualquier borde antialias.
    seguro = alfa.filter(ImageFilter.MinFilter(21))
    ps = seguro.load()

    # Primer punto de la diagonal que ya es fondo seguro: marca hasta dónde
    # llega la esquina redondeada.
    c = next(k for k in range(min(w, h) // 2) if ps[k, k] == 255)

    base = im.convert('RGB')
    pb = base.load()
    salida = base.copy()
    po = salida.load()
    # Para cada píxel dudoso se busca el píxel seguro más próximo avanzando
    # hacia el centro. Cerca del filo siempre aparece fondo antes que
    # contenido; saltar directamente más adentro arrastraba el «$» verde hasta
    # el borde. Lo que no encuentre nada (el rincón extremo de una esquina, que
    # la máscara del sistema recorta igualmente) toma el azul de fondo.
    for y in range(h):
        for x in range(w):
            if ps[x, y] == 255:
                continue
            color = FONDO
            for d in range(1, c + 1):
                cx = min(max(x, d), w - 1 - d)
                cy = min(max(y, d), h - 1 - d)
                if ps[cx, cy] == 255:
                    color = pb[cx, cy]
                    break
            po[x, y] = color
    return salida


def redondeado(im, radio_rel=0.22):
    """Versión con esquinas redondeadas y fondo transparente, para el icono
    heredado de Android, que el sistema no recorta."""
    lado = im.size[0]
    mascara = Image.new('L', (lado, lado), 0)
    ImageDraw.Draw(mascara).rounded_rectangle(
        (0, 0, lado - 1, lado - 1), radius=int(lado * radio_rel), fill=255
    )
    salida = im.convert('RGBA')
    salida.putalpha(mascara)
    return salida


def main():
    fuente = Image.open(FUENTE).convert('RGBA')
    maestro = a_sangre(fuente.crop(cuadro_oscuro(fuente))).resize(
        (1024, 1024), Image.LANCZOS
    )

    # ── iOS: los tamaños salen del propio Contents.json ──────────────────────
    contenido = json.loads((IOS / 'Contents.json').read_text(encoding='utf-8'))
    for img in contenido['images']:
        base = float(img['size'].split('x')[0])
        escala = int(img['scale'].rstrip('x'))
        lado = round(base * escala)
        maestro.resize((lado, lado), Image.LANCZOS).save(IOS / img['filename'])

    # ── Android heredado (anterior a 8.0): redondeado, sin máscara del sistema
    densidades = {'mdpi': 1, 'hdpi': 1.5, 'xhdpi': 2, 'xxhdpi': 3, 'xxxhdpi': 4}
    redondo = redondeado(maestro)
    for nombre, factor in densidades.items():
        lado = round(48 * factor)
        redondo.resize((lado, lado), Image.LANCZOS).save(
            RES / f'mipmap-{nombre}/ic_launcher.png'
        )

    # ── Android adaptativo (8.0+): lienzo de 108 dp, zona visible ~72 dp ─────
    # El icono ocupa 64 dp centrados. El «$» queda casi en la esquina del
    # dibujo, y con más tamaño la máscara circular —la más común— lo cortaba.
    # A 64 dp todo el contenido cae dentro del círculo seguro de 66 dp; el
    # margen sobrante lo cubre la capa de fondo, del mismo azul que el borde.
    for nombre, factor in densidades.items():
        lienzo = round(108 * factor)
        lado = round(64 * factor)
        # El borde del dibujo se funde hacia transparente: sin eso se veía una
        # costura cuadrada donde el degradado del icono toca el fondo liso.
        dibujo = maestro.resize((lado, lado), Image.LANCZOS).convert('RGBA')
        fundido = round(6 * factor)
        mascara = Image.new('L', (lado, lado), 0)
        ImageDraw.Draw(mascara).rectangle(
            (fundido, fundido, lado - 1 - fundido, lado - 1 - fundido), fill=255
        )
        dibujo.putalpha(mascara.filter(ImageFilter.GaussianBlur(fundido / 2)))
        frente = Image.new('RGBA', (lienzo, lienzo), (0, 0, 0, 0))
        frente.paste(dibujo, ((lienzo - lado) // 2, (lienzo - lado) // 2), dibujo)
        frente.save(RES / f'mipmap-{nombre}/ic_launcher_foreground.png')

    (RES / 'mipmap-anydpi-v26').mkdir(exist_ok=True)
    (RES / 'mipmap-anydpi-v26/ic_launcher.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background"/>\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '</adaptive-icon>\n',
        encoding='utf-8',
    )
    # Media del borde del icono: la capa de fondo debe continuarlo sin costura.
    pm = maestro.load()
    borde = [pm[x, y] for x in range(1024) for y in (4, 1019)] + [
        pm[x, y] for y in range(1024) for x in (4, 1019)
    ]
    fondo = tuple(sum(c[i] for c in borde) // len(borde) for i in range(3))
    (RES / 'values/ic_launcher_background.xml').write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<resources>\n'
        f'    <color name="ic_launcher_background">#{fondo[0]:02X}{fondo[1]:02X}{fondo[2]:02X}</color>\n'
        '</resources>\n',
        encoding='utf-8',
    )
    print('Iconos generados.')


if __name__ == '__main__':
    main()
