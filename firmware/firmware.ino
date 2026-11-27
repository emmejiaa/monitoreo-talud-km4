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

// HC-05: TXD del módulo -> pin 10, RXD del módulo -> pin 11
SoftwareSerial bluetooth(10, 11);

const int PIN_HUMEDAD      = A0;
const int PIN_EXTENSOMETRO = A1;
const int PIN_LED_VERDE    = 5;
const int PIN_LED_AMARILLO = 3;
const int PIN_LED_ROJO     = 4;
// MPU6050 por I2C: SDA = A4, SCL = A5

const float EXT_RECORRIDO_MM = 60.0;

// El MPU6050 se lee directo por I2C, sin librería: los GY-521 clon traen chips
// que la librería de Adafruit rechaza por su número de identificación
const byte MPU_DIRECCION = 0x68;
const byte MPU_PWR_MGMT_1 = 0x6B;
const byte MPU_CONFIG = 0x1A;
const byte MPU_ACCEL_CONFIG = 0x1C;
const byte MPU_ACCEL_XOUT_H = 0x3B;

const unsigned long INTERVALO_LECTURA_MS   = 200;
const unsigned long MPU_INIT_TIMEOUT_MS    = 800;
const unsigned long MPU_REINTENTO_MS       = 5000;
const byte MPU_FALLOS_PARA_PERDIDO         = 5;
const byte EXT_LECTURAS_PARA_CAMBIO        = 3;
const byte MUESTRAS_LINEA_BASE             = 16;
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

struct Lectura {
  float humedad;
  float inclinacion;
  float desplazamiento;
  // Dirección de la gravedad vista por el MPU6050 (unidades crudas)
  float gx, gy, gz;
};

Lectura lecturaActual = {0, 0, 0, 0, 0, 0};
Lectura lineaBase     = {0, 0, 0, 0, 0, 0};
int crudoHumedad      = 0;
// La referencia de humedad se guarda en lectura cruda para que siga valiendo
// si cambia la calibración
float baseCrudoHumedad = 0;
int crudoExtensometro = 0;
int nivelAlerta = 0;

bool mpuOk = false;
bool baseInclinacionOk = false;
byte fallosMpu = 0;
unsigned long ultimoIntentoMpu = 0;

bool extOk = false;
bool baseDisOk = false;
byte extLecturasDistintas = 0;

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

float humedadDesdeCrudo(float raw) {
  float pct = 100.0 * (cfg.humSeco - raw) / (float)(cfg.humSeco - cfg.humMojado);
  if (pct < 0) pct = 0;
  if (pct > 100) pct = 100;
  return pct;
}

float cambioHumedad() {
  return lecturaActual.humedad - humedadDesdeCrudo(baseCrudoHumedad);
}

void aplicarCalibracion() {
  lecturaActual.humedad = humedadDesdeCrudo(crudoHumedad);
  lineaBase.humedad = humedadDesdeCrudo(baseCrudoHumedad);
}

// Mensaje de texto por USB y por Bluetooth
void avisar(const __FlashStringHelper *msg) {
  Serial.println(msg);
  bluetooth.println(msg);
}

bool mpuEscribir(byte registro, byte valor) {
  Wire.beginTransmission(MPU_DIRECCION);
  Wire.write(registro);
  Wire.write(valor);
  return Wire.endTransmission() == 0;
}

bool mpuLeerAceleracion(float &x, float &y, float &z) {
  Wire.beginTransmission(MPU_DIRECCION);
  Wire.write(MPU_ACCEL_XOUT_H);
  if (Wire.endTransmission(false) != 0) return false;
  if (Wire.requestFrom(MPU_DIRECCION, (byte)6) != 6) return false;
  // Cada byte en su propia línea: en C++ no está garantizado el orden de dos
  // llamadas a read() dentro de la misma expresión
  int16_t v[3];
  for (byte i = 0; i < 3; i++) {
    byte alto = Wire.read();
    byte bajo = Wire.read();
    v[i] = (int16_t)((alto << 8) | bajo);
  }
  if (v[0] == 0 && v[1] == 0 && v[2] == 0) return false;
  x = v[0];
  y = v[1];
  z = v[2];
  return true;
}

// Promedio de varias lecturas para bajar el ruido
bool mpuLeerPromedio(byte muestras, float &x, float &y, float &z) {
  float sx = 0, sy = 0, sz = 0;
  byte buenas = 0;
  for (byte i = 0; i < muestras; i++) {
    float a, b, c;
    if (mpuLeerAceleracion(a, b, c)) {
      sx += a; sy += b; sz += c;
      buenas++;
    }
  }
  if (buenas == 0) return false;
  x = sx / buenas;
  y = sy / buenas;
  z = sz / buenas;
  return true;
}

// Inclinación respecto a la vertical del sensor (eje Z), en cualquier dirección
float inclinacionDesde(float x, float y, float z) {
  return atan2(sqrt(x * x + y * y), z) * 180.0 / PI;
}

// Ángulo entre la posición de referencia y la actual: detecta un giro en
// cualquier dirección, sin importar cómo quedó montado el sensor
float cambioInclinacion() {
  if (!baseInclinacionOk) return 0;
  const Lectura &a = lineaBase;
  const Lectura &b = lecturaActual;
  float cx = a.gy * b.gz - a.gz * b.gy;
  float cy = a.gz * b.gx - a.gx * b.gz;
  float cz = a.gx * b.gy - a.gy * b.gx;
  float cruz = sqrt(cx * cx + cy * cy + cz * cz);
  float punto = a.gx * b.gx + a.gy * b.gy + a.gz * b.gz;
  return atan2(cruz, punto) * 180.0 / PI;
}

void leerInclinacion() {
  if (!mpuOk) return;
  float x, y, z;
  if (mpuLeerPromedio(4, x, y, z)) {
    fallosMpu = 0;
    lecturaActual.gx = x;
    lecturaActual.gy = y;
    lecturaActual.gz = z;
    lecturaActual.inclinacion = inclinacionDesde(x, y, z);
  } else if (++fallosMpu >= MPU_FALLOS_PARA_PERDIDO) {
    mpuOk = false;
    ultimoIntentoMpu = millis();
    avisar(F("[!!] Se perdio la conexion con el MPU6050"));
  }
}

// Convierte el canal interno de 0 V para dejar descargado el condensador
// de muestreo del ADC
void descargarAdc() {
  ADMUX = (ADMUX & 0xF0) | 0x0F;
  ADCSRA |= _BV(ADSC);
  while (ADCSRA & _BV(ADSC)) {}
}

// Un pin analógico al aire no lee 0: copia lo que quedó en el ADC y da
// valores falsos. Con la resistencia interna de pull-up un pin al aire sube
// a 5 V y luego, cada vez que se descarga el ADC, se va cayendo; el
// potenciómetro, en cambio, mantiene su voltaje en las dos pruebas.
bool extensometroPresente() {
  pinMode(PIN_EXTENSOMETRO, INPUT_PULLUP);
  delayMicroseconds(50);
  int conPullup = analogRead(PIN_EXTENSOMETRO);
  pinMode(PIN_EXTENSOMETRO, INPUT);
  if (conPullup < 1000) return true;
  int v = 0;
  for (byte i = 0; i < 10; i++) {
    descargarAdc();
    v = analogRead(PIN_EXTENSOMETRO);
  }
  return v >= 960;
}

void olvidarDesplazamiento() {
  lecturaActual.desplazamiento = 0;
  crudoExtensometro = 0;
}

// Cambia de estado solo si varias lecturas seguidas coinciden
void revisarExtensometro(bool presente) {
  if (presente == extOk) {
    extLecturasDistintas = 0;
    return;
  }
  if (++extLecturasDistintas < EXT_LECTURAS_PARA_CAMBIO) return;
  extLecturasDistintas = 0;
  extOk = presente;
  if (extOk) {
    avisar(F("[OK] Extensometro conectado"));
  } else {
    olvidarDesplazamiento();
    avisar(F("[!!] Se perdio la conexion con el extensometro"));
  }
}

void leerSensores() {
  crudoHumedad          = leerPromedio(PIN_HUMEDAD, 5);
  lecturaActual.humedad = humedadDesdeCrudo(crudoHumedad);

  bool presente = extensometroPresente();
  revisarExtensometro(presente);
  if (presente && extOk) {
    crudoExtensometro = leerPromedio(PIN_EXTENSOMETRO, 5);
    lecturaActual.desplazamiento = (crudoExtensometro / 1023.0) * EXT_RECORRIDO_MM;
    if (!baseDisOk) {
      lineaBase.desplazamiento = lecturaActual.desplazamiento;
      baseDisOk = true;
    }
  }
  leerInclinacion();
}

float cambioDesplazamiento() {
  if (!extOk || !baseDisOk) return 0;
  return lecturaActual.desplazamiento - lineaBase.desplazamiento;
}

int nivelPorDelta(float delta, float amarillo, float rojo) {
  if (delta >= rojo) return 2;
  if (delta >= amarillo) return 1;
  return 0;
}

int calcularNivelAlerta() {
  // Humedad: solo subida importa (bajada es drenaje normal)
  float dHum = cambioHumedad();
  float dDis = fabs(cambioDesplazamiento());

  int nivel = max(nivelPorDelta(dHum, cfg.humAmarillo, cfg.humRojo),
                  nivelPorDelta(dDis, cfg.disAmarillo, cfg.disRojo));
  if (mpuOk) {
    nivel = max(nivel, nivelPorDelta(cambioInclinacion(), cfg.incAmarillo, cfg.incRojo));
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
  out.print(F(",\"dhum\":"));    out.print(cambioHumedad(), 2);
  out.print(F(",\"dinc\":"));    out.print(cambioInclinacion(), 2);
  out.print(F(",\"ddis\":"));    out.print(cambioDesplazamiento(), 2);
  out.print(F(",\"a\":"));       out.print(nivelAlerta);
  out.print(F(",\"inc_ok\":"));  out.print(mpuOk ? F("true") : F("false"));
  out.print(F(",\"dis_ok\":"));  out.print(extOk ? F("true") : F("false"));
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

// Promedia varias lecturas para que la referencia no quede corrida por el ruido.
// Hay que tener el montaje quieto mientras tanto (menos de medio segundo).
void tomarLineaBase() {
  long crudoHum = 0;
  float dis = 0, gx = 0, gy = 0, gz = 0;
  byte conMpu = 0, conExt = 0;
  for (byte i = 0; i < MUESTRAS_LINEA_BASE; i++) {
    leerSensores();
    crudoHum += crudoHumedad;
    if (extOk) {
      dis += lecturaActual.desplazamiento;
      conExt++;
    }
    if (mpuOk) {
      gx += lecturaActual.gx;
      gy += lecturaActual.gy;
      gz += lecturaActual.gz;
      conMpu++;
    }
    delay(10);
  }
  lineaBase = lecturaActual;
  baseCrudoHumedad = crudoHum / (float)MUESTRAS_LINEA_BASE;
  lineaBase.humedad = humedadDesdeCrudo(baseCrudoHumedad);
  // Un sensor que no estaba conectado toma su referencia cuando aparezca
  baseDisOk = conExt > 0;
  if (baseDisOk) lineaBase.desplazamiento = dis / conExt;
  baseInclinacionOk = conMpu > 0;
  if (baseInclinacionOk) {
    lineaBase.gx = gx / conMpu;
    lineaBase.gy = gy / conMpu;
    lineaBase.gz = gz / conMpu;
    lineaBase.inclinacion = inclinacionDesde(lineaBase.gx, lineaBase.gy, lineaBase.gz);
  }
}

void reiniciarLineaBase() {
  tomarLineaBase();
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
  // No se retoma la línea base: al calibrar "mojado" el sensor está en agua
  // y la referencia quedaría en 100 %. Como está guardada en lectura cruda,
  // sigue valiendo con la calibración nueva.
  aplicarCalibracion();
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
    aplicarCalibracion();
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

// Despierta el MPU6050 (arranca dormido), ±2 g y filtro de ~21 Hz.
// Cuenta como detectado solo si además entrega una lectura válida.
bool configurarMPU() {
  if (!mpuEscribir(MPU_PWR_MGMT_1, 0x00)) return false;
  mpuEscribir(MPU_ACCEL_CONFIG, 0x00);
  mpuEscribir(MPU_CONFIG, 0x04);
  delay(30);
  float x, y, z;
  return mpuLeerAceleracion(x, y, z);
}

bool intentarInicializarMPU() {
  Wire.begin();
  Wire.setClock(100000);
  // Sin esto, un cable suelto en SDA/SCL puede dejar el Arduino congelado
#if defined(WIRE_HAS_TIMEOUT)
  Wire.setWireTimeout(3000, true);
#endif

  unsigned long inicio = millis();
  while (millis() - inicio < MPU_INIT_TIMEOUT_MS) {
    if (configurarMPU()) return true;
    delay(50);
  }
  return false;
}

// Si el MPU6050 no estaba o se soltó un cable, se reintenta cada pocos segundos.
// Si nunca tuvo referencia, toma la posición actual como referencia.
void revisarReconexionMPU() {
  if (mpuOk || millis() - ultimoIntentoMpu < MPU_REINTENTO_MS) return;
  ultimoIntentoMpu = millis();
  if (!configurarMPU()) return;
  mpuOk = true;
  fallosMpu = 0;
  leerInclinacion();
  avisar(F("[OK] MPU6050 conectado"));
  if (!baseInclinacionOk) {
    lineaBase.gx = lecturaActual.gx;
    lineaBase.gy = lecturaActual.gy;
    lineaBase.gz = lecturaActual.gz;
    lineaBase.inclinacion = lecturaActual.inclinacion;
    baseInclinacionOk = true;
  }
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

  baseInclinacionOk = false;
  mpuOk = intentarInicializarMPU();
  ultimoIntentoMpu = millis();
  if (mpuOk) {
    avisar(F("[OK] MPU6050 detectado"));
  } else {
    avisar(F("[!!] MPU6050 no detectado - operando sin inclinacion"));
  }

  baseDisOk = false;
  extLecturasDistintas = 0;
  extOk = extensometroPresente();
  if (extOk) {
    avisar(F("[OK] Extensometro detectado"));
  } else {
    olvidarDesplazamiento();
    avisar(F("[!!] Extensometro no detectado - operando sin desplazamiento"));
  }

  delay(500);
  tomarLineaBase();
  avisar(F("[OK] Linea base inicial establecida"));
  enviarConfig();
}

void loop() {
  revisarComandos(Serial, lectorUsb);
  if (revisarComandos(bluetooth, lectorBt)) ultimoRxBt = millis();
  revisarReconexionMPU();

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
