# Monitoreo del talud — Km 4 Autopista Medellín–Bogotá

Prototipo de bajo costo para vigilar el riesgo de deslizamiento en el talud del Km 4. Mide humedad del suelo, inclinación y desplazamiento, compara cada valor contra una **línea base** y da alerta verde, amarilla o roja en LEDs, en un dashboard en la laptop y en una app Android.

Proyecto Integrado en Ingeniería (Seminario 3) — Universidad Nacional de Colombia, Facultad de Minas, 2026-2.

## Cómo funciona

```
 Sensor de humedad ─┐
 Extensómetro ──────┼─► Arduino UNO ──USB──────► Dashboard en la laptop (Chrome/Edge)
 MPU6050 ───────────┘        │
                             ├──HC-05 (Bluetooth)─► App Android
                             └──► LEDs verde / amarillo / rojo
```

Las alertas no dependen del valor absoluto sino de **cuánto cambió cada sensor desde la línea base** (la lectura tomada al encender o al pulsar "Reiniciar línea base"):

| Sensor | Amarilla | Roja | Nota |
|---|---|---|---|
| Humedad | +15 % | +25 % | Solo cuenta cuando sube |
| Inclinación | 2,5° | 5° | Ángulo entre la posición de referencia y la actual, en cualquier dirección |
| Desplazamiento | 3 mm | 6 mm | Cambio en cualquier sentido |

Son los valores de fábrica. Se pueden cambiar desde la app o el dashboard sin recompilar y quedan guardados en la EEPROM del Arduino.

## Contenido del repositorio

| Carpeta | Qué es |
|---|---|
| `firmware/` | Firmware del Arduino UNO (`firmware.ino`) y dashboard para la laptop (`dashboard_serial.html`) |
| `app/` | App Android en Flutter |

## Hardware

| Componente | Pin del Arduino UNO |
|---|---|
| Sensor de humedad del suelo (salida analógica) | A0 |
| Extensómetro (potenciómetro lineal, 60 mm) | A1 |
| MPU6050 / GY-521 | SDA → A4, SCL → A5, VCC → 5V |
| LED verde / amarillo / rojo | 2 / 3 / 4 |
| HC-05 | TXD → 10, RXD → 11 (con divisor 1 kΩ + 2 kΩ) |

El MPU6050 se lee directo por I2C, sin librerías, así que también funciona con los GY-521 clon que la librería de Adafruit rechaza. Es opcional: si no está conectado, el firmware sigue funcionando, la inclinación aparece como "N/D" y, si se conecta después o se suelta un cable, se detecta solo en unos segundos.

## Firmware

1. Instalar Arduino IDE 2.x. No hace falta ninguna librería adicional.
2. Abrir `firmware/firmware.ino`, elegir "Arduino Uno" y subir. No hay que cambiarle el nombre a la carpeta: Arduino exige que se llame igual que el `.ino`.
3. El Monitor Serie va a 9600 baudios con fin de línea "Nueva línea".

Los datos salen como una línea JSON: por USB cada 400 ms y por Bluetooth cada 1 s.

```json
{"hum":54.00,"inc":0.00,"dis":30.12,"dhum":0.00,"dinc":0.00,"ddis":0.00,"a":0,"inc_ok":false,"hum_raw":557,"dis_raw":513}
```

`a` es el nivel de alerta (0 verde, 1 amarilla, 2 roja). Los campos que empiezan por `d` son el cambio respecto a la línea base (`dinc` es el ángulo entre la posición de referencia y la actual, siempre positivo), e `inc_ok` indica si el MPU6050 respondió.

Comandos, uno por línea, por USB o por Bluetooth:

| Comando | Efecto |
|---|---|
| `r` | Reinicia la línea base |
| `cfg` | Muestra calibración y límites (`{"cfg":1,...}`) |
| `cal seco` / `cal mojado` | Toma la lectura actual del sensor de humedad como seco o mojado |
| `cal <seco> <mojado>` | Fija la calibración a mano (0–1023) |
| `umb hum\|inc\|dis <amarilla> <roja>` | Cambia los límites de un sensor |
| `fabrica` | Vuelve a los valores de fábrica |

## Dashboard (laptop)

Abrir `firmware/dashboard_serial.html` en Chrome o Edge (usa Web Serial) y elegir cómo conectarse:

- **USB**: elegir el puerto COM del Arduino. El Monitor Serie del Arduino IDE tiene que estar cerrado.
- **Bluetooth**: el HC-05 debe estar emparejado antes en Windows (PIN 1234 o 0000). Recibe una lectura por segundo. El HC-05 acepta una sola conexión, así que mientras la laptop lo use, el celular no puede conectarse.
- **Modo simulado**: datos de prueba sin Arduino, para mostrarlo o probarlo.

Tiene lo mismo que la app:

- estado, sensores y gráfica de los últimos 3 minutos con las franjas de alerta;
- sonido en las alertas;
- calibración del sensor de humedad y cambio de límites;
- bitácora de eventos.

Si se pierde la conexión, se reconecta solo; con "Desconectar" se puede cambiar de modo sin recargar la página.

## App Android

- Se conecta al HC-05 (hay que emparejarlo antes en Ajustes → Bluetooth, PIN 1234 o 0000) y se reconecta sola si se pierde la señal.
- Muestra el estado, los tres sensores y una gráfica de los últimos 3 minutos.
- Las alertas suenan y la roja además vibra.
- Tiene una bitácora de eventos y una pantalla para calibrar el sensor de humedad y cambiar los límites.
- Incluye un **modo simulado** para probarla sin Arduino.
- No funciona en iPhone, porque iOS no permite Bluetooth clásico.

Para compilarla hace falta Flutter 3.50 o superior:

```bash
cd app
flutter test
flutter build apk --release --split-per-abi
```

El APK para la mayoría de celulares queda en `build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.
