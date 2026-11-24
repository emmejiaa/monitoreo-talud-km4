// Prototipo Km 4 — versión Arduino UNO + Bluetooth HC-05
// Los datos salen como una línea JSON: por USB cada 400 ms (dashboard en la
// laptop) y por el HC-05 cada 1 s (app del celular).
// Comandos, uno por línea, por USB o Bluetooth:
//   r                          reinicia la línea base
//   cfg                        muestra calibración y límites
//   cal seco | cal mojado      toma la lectura actual del sensor de humedad
//   cal <seco> <mojado>        fija la calibración a mano
//   umb hum|inc|dis <amarilla> <roja>
//   fabrica                    vuelve a los valores por defecto
// La calibración y los límites quedan guardados en la EEPROM.

#include <SoftwareSerial.h>
#include <Wire.h>
#include <EEPROM.h>
#include <Adafruit_MPU6050.h>
#include <Adafruit_Sensor.h>

// HC-05: TXD del módulo -> pin 10, RXD del módulo -> pin 11
SoftwareSerial bluetooth(10, 11);

const int PIN_HUMEDAD      = A0;
const int PIN_EXTENSOMETRO = A1;
const int PIN_LED_VERDE    = 2;
const int PIN_LED_AMARILLO = 3;
const int PIN_LED_ROJO     = 4;
// MPU6050 por I2C: SDA = A4, SCL = A5

const float EXT_RECORRIDO_MM = 60.0;

const unsigned long INTERVALO_LECTURA_MS   = 200;
const unsigned long MPU_INIT_TIMEOUT_MS    = 800;
const unsigned long INTERVALO_ENVIO_USB_MS = 400;
// SoftwareSerial no recibe mientras transmite: se envía por Bluetooth con
// menos frecuencia y se pausa un momento cuando está llegando un comando
const unsigned long INTERVALO_ENVIO_BT_MS  = 1000;
const unsigned long PAUSA_BT_TRAS_RX_MS    = 300;
const unsigned long TIMEOUT_COMANDO_MS     = 300;

struct Config {
  uint16_t marca;
  int humSeco;
  int humMojado;
  float humAmarillo, humRojo;
  float incAmarillo, incRojo;
  float disAmarillo, disRojo;
};

const uint16_t MARCA_CONFIG = 0x4B34;
const Config CONFIG_FABRICA = {MARCA_CONFIG, 800, 350, 15.0, 25.0, 2.5, 5.0, 3.0, 6.0};
Config cfg;

Adafruit_MPU6050 mpu;

struct Lectura {
  float humedad;
  float inclinacion;
  float desplazamiento;
};

Lectura lecturaActual = {0, 0, 0};
Lectura lineaBase     = {0, 0, 0};
int crudoHumedad      = 0;
int crudoExtensometro = 0;
int nivelAlerta = 0;

bool mpuOk = false;

struct LectorComandos {
  char buf[40];
  byte largo;
  bool descartando;
  unsigned long ultimoChar;
};

LectorComandos lectorUsb = {{0}, 0, false, 0};
LectorComandos lectorBt  = {{0}, 0, false, 0};
unsigned long ultimoRxBt = 0;

bool calibracionValida(int seco, int mojado) {
  return seco >= 0 && seco <= 1023 && mojado >= 0 && mojado <= 1023 &&
         abs(seco - mojado) >= 50;
}

bool limitesValidos(float amarillo, float rojo, float maximo) {
  return amarillo > 0 && rojo > amarillo && rojo <= maximo;
}

bool configValida(const Config &c) {
  return c.marca == MARCA_CONFIG &&
         calibracionValida(c.humSeco, c.humMojado) &&
         limitesValidos(c.humAmarillo, c.humRojo, 100) &&
         limitesValidos(c.incAmarillo, c.incRojo, 45) &&
         limitesValidos(c.disAmarillo, c.disRojo, EXT_RECORRIDO_MM);
}

bool cargarConfig() {
  EEPROM.get(0, cfg);
  if (configValida(cfg)) return true;
  cfg = CONFIG_FABRICA;
  return false;
}

void guardarConfig() {
  EEPROM.put(0, cfg);
}

int leerPromedio(int pin, int muestras) {
  long suma = 0;
  for (int i = 0; i < muestras; i++) {
    suma += analogRead(pin);
    delay(2);
  }
  return suma / muestras;
}

float humedadDesdeCrudo(int raw) {
  float pct = 100.0 * (cfg.humSeco - raw) / (float)(cfg.humSeco - cfg.humMojado);
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return pct;
}

float leerInclinacion() {
  if (!mpuOk) return 0.0;
  sensors_event_t a, g, temp;
  mpu.getEvent(&a, &g, &temp);
  float mag_horizontal = sqrt(a.acceleration.x * a.acceleration.x +
                              a.acceleration.y * a.acceleration.y);
  return atan2(mag_horizontal, a.acceleration.z) * 180.0 / PI;
}

void leerSensores() {
  crudoHumedad      = leerPromedio(PIN_HUMEDAD, 5);
  crudoExtensometro = leerPromedio(PIN_EXTENSOMETRO, 5);
  lecturaActual.humedad        = humedadDesdeCrudo(crudoHumedad);
  lecturaActual.desplazamiento = (crudoExtensometro / 1023.0) * EXT_RECORRIDO_MM;
  lecturaActual.inclinacion    = leerInclinacion();
}

int nivelPorDelta(float delta, float amarillo, float rojo) {
  if (delta >= rojo) return 2;
  if (delta >= amarillo) return 1;
  return 0;
}

int calcularNivelAlerta() {
  // Humedad: solo subida importa (bajada es drenaje normal)
  float dHum = lecturaActual.humedad - lineaBase.humedad;
  float dDis = fabs(lecturaActual.desplazamiento - lineaBase.desplazamiento);

  int nivel = max(nivelPorDelta(dHum, cfg.humAmarillo, cfg.humRojo),
                  nivelPorDelta(dDis, cfg.disAmarillo, cfg.disRojo));
  if (mpuOk) {
    float dInc = fabs(lecturaActual.inclinacion - lineaBase.inclinacion);
    nivel = max(nivel, nivelPorDelta(dInc, cfg.incAmarillo, cfg.incRojo));
  }
  return nivel;
}

void actualizarSalidas(int nivel) {
  digitalWrite(PIN_LED_VERDE,    nivel == 0 ? HIGH : LOW);
  digitalWrite(PIN_LED_AMARILLO, nivel == 1 ? HIGH : LOW);
  digitalWrite(PIN_LED_ROJO,     nivel == 2 ? HIGH : LOW);
}

// Una línea JSON por envío; se imprime por partes para no usar String
// (el UNO solo tiene 2 KB de RAM)
void enviarDatos(Stream &out) {
  out.print(F("{\"hum\":"));     out.print(lecturaActual.humedad, 2);
  out.print(F(",\"inc\":"));     out.print(lecturaActual.inclinacion, 2);
  out.print(F(",\"dis\":"));     out.print(lecturaActual.desplazamiento, 2);
  out.print(F(",\"dhum\":"));    out.print(lecturaActual.humedad - lineaBase.humedad, 2);
  out.print(F(",\"dinc\":"));    out.print(lecturaActual.inclinacion - lineaBase.inclinacion, 2);
  out.print(F(",\"ddis\":"));    out.print(lecturaActual.desplazamiento - lineaBase.desplazamiento, 2);
  out.print(F(",\"a\":"));       out.print(nivelAlerta);
  out.print(F(",\"inc_ok\":"));  out.print(mpuOk ? F("true") : F("false"));
  out.print(F(",\"hum_raw\":")); out.print(crudoHumedad);
  out.print(F(",\"dis_raw\":")); out.print(crudoExtensometro);
  out.println(F("}"));
}

void imprimirConfig(Stream &out) {
  out.print(F("{\"cfg\":1,\"hum_seco\":")); out.print(cfg.humSeco);
  out.print(F(",\"hum_mojado\":"));         out.print(cfg.humMojado);
  out.print(F(",\"hum_am\":"));             out.print(cfg.humAmarillo, 2);
  out.print(F(",\"hum_ro\":"));             out.print(cfg.humRojo, 2);
  out.print(F(",\"inc_am\":"));             out.print(cfg.incAmarillo, 2);
  out.print(F(",\"inc_ro\":"));             out.print(cfg.incRojo, 2);
  out.print(F(",\"dis_am\":"));             out.print(cfg.disAmarillo, 2);
  out.print(F(",\"dis_ro\":"));             out.print(cfg.disRojo, 2);
  out.println(F("}"));
}

void enviarConfig() {
  imprimirConfig(Serial);
  imprimirConfig(bluetooth);
}

// Mensaje de texto por USB y por Bluetooth
void avisar(const __FlashStringHelper *msg) {
  Serial.println(msg);
  bluetooth.println(msg);
}

void reiniciarLineaBase() {
  lineaBase = lecturaActual;
  avisar(F(">> Linea base reiniciada"));
}

bool aNumero(const char *s, float &valor) {
  if (s == NULL) return false;
  char *fin;
  valor = strtod(s, &fin);
  return fin != s && *fin == '\0';
}

void comandoCal() {
  char *a = strtok(NULL, " ");
  char *b = strtok(NULL, " ");
  int seco = cfg.humSeco;
  int mojado = cfg.humMojado;
  float fa, fb;

  if (a != NULL && b == NULL && strcmp(a, "seco") == 0) {
    seco = leerPromedio(PIN_HUMEDAD, 20);
  } else if (a != NULL && b == NULL && strcmp(a, "mojado") == 0) {
    mojado = leerPromedio(PIN_HUMEDAD, 20);
  } else if (aNumero(a, fa) && aNumero(b, fb) && strtok(NULL, " ") == NULL &&
             fa >= 0 && fa <= 1023 && fb >= 0 && fb <= 1023) {
    seco = round(fa);
    mojado = round(fb);
  } else {
    avisar(F(">> Error: use cal seco, cal mojado o cal <seco> <mojado>"));
    return;
  }

  if (!calibracionValida(seco, mojado)) {
    avisar(F(">> Error: seco y mojado deben diferir al menos 50 (rango 0-1023)"));
    return;
  }
  cfg.humSeco = seco;
  cfg.humMojado = mojado;
  guardarConfig();
  avisar(F(">> Calibracion guardada"));
  // Con la calibración nueva la humedad en % cambia de golpe; se toma como
  // nueva referencia para que no salte una alerta falsa
  leerSensores();
  reiniciarLineaBase();
  enviarConfig();
}

void comandoUmb() {
  char *sensor = strtok(NULL, " ");
  float amarillo, rojo;
  bool ok = sensor != NULL &&
            aNumero(strtok(NULL, " "), amarillo) &&
            aNumero(strtok(NULL, " "), rojo) &&
            strtok(NULL, " ") == NULL;
  float *pAmarillo = NULL;
  float *pRojo = NULL;
  float maximo = 0;
  if (ok && strcmp(sensor, "hum") == 0) {
    pAmarillo = &cfg.humAmarillo; pRojo = &cfg.humRojo; maximo = 100;
  } else if (ok && strcmp(sensor, "inc") == 0) {
    pAmarillo = &cfg.incAmarillo; pRojo = &cfg.incRojo; maximo = 45;
  } else if (ok && strcmp(sensor, "dis") == 0) {
    pAmarillo = &cfg.disAmarillo; pRojo = &cfg.disRojo; maximo = EXT_RECORRIDO_MM;
  }
  if (pAmarillo == NULL) {
    avisar(F(">> Error: use umb hum|inc|dis <amarilla> <roja>"));
    return;
  }
  if (!limitesValidos(amarillo, rojo, maximo)) {
    avisar(F(">> Error: limites fuera de rango (0 < amarilla < roja)"));
    return;
  }
  *pAmarillo = amarillo;
  *pRojo = rojo;
  guardarConfig();
  avisar(F(">> Limites guardados"));
  enviarConfig();
}

void ejecutarComando(char *linea) {
  char *cmd = strtok(linea, " ");
  if (cmd == NULL) return;
  if (strcmp(cmd, "r") == 0) {
    reiniciarLineaBase();
  } else if (strcmp(cmd, "cfg") == 0) {
    enviarConfig();
  } else if (strcmp(cmd, "cal") == 0) {
    comandoCal();
  } else if (strcmp(cmd, "umb") == 0) {
    comandoUmb();
  } else if (strcmp(cmd, "fabrica") == 0) {
    cfg = CONFIG_FABRICA;
    guardarConfig();
    avisar(F(">> Valores de fabrica restaurados"));
    leerSensores();
    reiniciarLineaBase();
    enviarConfig();
  } else {
    avisar(F(">> Error: comando no reconocido"));
  }
}

// Arma la línea letra por letra; si pasa mucho tiempo entre letras se
// descarta lo anterior (un pedazo de comando que se perdió)
bool revisarComandos(Stream &in, LectorComandos &l) {
  bool recibio = false;
  while (in.available()) {
    char c = in.read();
    recibio = true;
    unsigned long ahora = millis();
    if (ahora - l.ultimoChar > TIMEOUT_COMANDO_MS) {
      l.largo = 0;
      l.descartando = false;
    }
    l.ultimoChar = ahora;

    if (c == '\n' || c == '\r') {
      if (l.largo > 0 && !l.descartando) {
        l.buf[l.largo] = '\0';
        ejecutarComando(l.buf);
      }
      l.largo = 0;
      l.descartando = false;
    } else if (l.largo < sizeof(l.buf) - 1) {
      l.buf[l.largo++] = tolower(c);
    } else {
      l.descartando = true;
    }
  }
  return recibio;
}

// Verifica con un ping I2C antes de llamar mpu.begin(), para evitar bloqueos
// cuando el módulo no está conectado
bool intentarInicializarMPU() {
  Wire.begin();
  Wire.setClock(100000);
#if defined(WIRE_HAS_TIMEOUT)
  Wire.setWireTimeout(3000, true);
#endif

  unsigned long inicio = millis();
  while (millis() - inicio < MPU_INIT_TIMEOUT_MS) {
    Wire.beginTransmission(0x68);
    if (Wire.endTransmission() == 0) {
      if (mpu.begin()) {
        mpu.setAccelerometerRange(MPU6050_RANGE_2_G);
        mpu.setGyroRange(MPU6050_RANGE_250_DEG);
        mpu.setFilterBandwidth(MPU6050_BAND_21_HZ);
        return true;
      }
    }
    delay(50);
  }
  return false;
}

void setup() {
  Serial.begin(9600);
  bluetooth.begin(9600);
  delay(300);
  Serial.println();
  avisar(F("Prototipo Km 4 (Arduino UNO) - iniciando"));

  pinMode(PIN_LED_VERDE,    OUTPUT);
  pinMode(PIN_LED_AMARILLO, OUTPUT);
  pinMode(PIN_LED_ROJO,     OUTPUT);
  digitalWrite(PIN_LED_VERDE,    HIGH);
  digitalWrite(PIN_LED_AMARILLO, LOW);
  digitalWrite(PIN_LED_ROJO,     LOW);

  if (cargarConfig()) {
    avisar(F("[OK] Ajustes cargados de la EEPROM"));
  } else {
    avisar(F("[--] Sin ajustes guardados - usando valores de fabrica"));
  }

  mpuOk = intentarInicializarMPU();
  if (mpuOk) {
    avisar(F("[OK] MPU6050 detectado"));
  } else {
    avisar(F("[!!] MPU6050 no detectado - operando sin inclinacion"));
  }

  delay(500);
  leerSensores();
  lineaBase = lecturaActual;
  avisar(F("[OK] Linea base inicial establecida"));
  enviarConfig();
}

void loop() {
  revisarComandos(Serial, lectorUsb);
  if (revisarComandos(bluetooth, lectorBt)) ultimoRxBt = millis();

  static unsigned long ultimaLectura = 0;
  if (millis() - ultimaLectura >= INTERVALO_LECTURA_MS) {
    ultimaLectura = millis();
    leerSensores();
    nivelAlerta = calcularNivelAlerta();
    actualizarSalidas(nivelAlerta);
  }

  static unsigned long ultimoEnvioUsb = 0;
  if (millis() - ultimoEnvioUsb >= INTERVALO_ENVIO_USB_MS) {
    ultimoEnvioUsb = millis();
    enviarDatos(Serial);
  }

  static unsigned long ultimoEnvioBt = 0;
  if (millis() - ultimoEnvioBt >= INTERVALO_ENVIO_BT_MS &&
      millis() - ultimoRxBt >= PAUSA_BT_TRAS_RX_MS) {
    ultimoEnvioBt = millis();
    enviarDatos(bluetooth);
  }
}
