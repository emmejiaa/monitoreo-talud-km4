package co.edu.unal.monitoreo_km4

import android.annotation.SuppressLint
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID

// Puerto serial sobre Bluetooth LE para módulos tipo HM-10, AT-09, JDY o
// HC-08 (servicio FFE0) o con el servicio UART de Nordic. Una conexión a la
// vez; cada intento lleva un id para descartar avisos de conexiones viejas.
@SuppressLint("MissingPermission")
class EnlaceBle(private val context: Context, messenger: BinaryMessenger) {
    private val principal = Handler(Looper.getMainLooper())
    private var eventos: EventChannel.EventSink? = null
    private var gatt: BluetoothGatt? = null
    private var idActual = -1
    private var escritura: BluetoothGattCharacteristic? = null
    private val pendientes = ArrayDeque<ByteArray>()
    private var escribiendo = false
    private var reintentosEscritura = 0

    init {
        MethodChannel(messenger, "km4/ble").setMethodCallHandler { call, result ->
            val id = call.argument<Int>("id") ?: -1
            when (call.method) {
                "conectar" -> result.success(conectar(id, call.argument<String>("direccion") ?: ""))
                "enviar" -> result.success(enviar(id, call.argument<ByteArray>("datos") ?: ByteArray(0)))
                "desconectar" -> {
                    if (id == idActual) {
                        cerrarGatt()
                        idActual = -1
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "km4/ble/eventos").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                eventos = sink
            }

            override fun onCancel(arguments: Any?) {
                eventos = null
            }
        })
    }

    fun cerrar() {
        cerrarGatt()
        idActual = -1
    }

    private fun conectar(id: Int, direccion: String): String? {
        cerrarGatt()
        idActual = id
        val adaptador = context.getSystemService(BluetoothManager::class.java)?.adapter
            ?: return "sin_bluetooth"
        return try {
            if (!adaptador.isEnabled) return "apagado"
            val dispositivo = adaptador.getRemoteDevice(direccion)
            gatt = dispositivo.connectGatt(context, false, Llamadas(id), BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) "fallo" else null
        } catch (e: SecurityException) {
            "permiso"
        } catch (e: IllegalArgumentException) {
            "direccion"
        }
    }

    private fun enviar(id: Int, datos: ByteArray): Boolean {
        if (id != idActual || gatt == null || escritura == null) return false
        var i = 0
        while (i < datos.size) {
            val fin = minOf(i + TROZO, datos.size)
            pendientes.addLast(datos.copyOfRange(i, fin))
            i = fin
        }
        escribirSiguiente()
        return true
    }

    @Suppress("DEPRECATION")
    private fun escribirSiguiente() {
        if (escribiendo) return
        val g = gatt ?: return
        val c = escritura ?: return
        val trozo = pendientes.pollFirst() ?: return
        val tipo = if (c.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
            BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        } else {
            BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        }
        val ok = if (Build.VERSION.SDK_INT >= 33) {
            g.writeCharacteristic(c, trozo, tipo) == BluetoothStatusCodes.SUCCESS
        } else {
            c.writeType = tipo
            c.value = trozo
            g.writeCharacteristic(c)
        }
        if (ok) {
            escribiendo = true
            reintentosEscritura = 0
        } else if (++reintentosEscritura <= 20) {
            // Android rechaza la escritura si todavía está ocupado con la anterior
            pendientes.addFirst(trozo)
            principal.postDelayed({ escribirSiguiente() }, 30)
        } else {
            pendientes.clear()
            reintentosEscritura = 0
        }
    }

    private fun cerrarGatt() {
        gatt?.let {
            try {
                it.disconnect()
            } catch (_: Exception) {
            }
            it.close()
        }
        gatt = null
        escritura = null
        pendientes.clear()
        escribiendo = false
    }

    private fun emitir(id: Int, tipo: String, detalle: String? = null, datos: ByteArray? = null) {
        eventos?.success(mapOf("id" to id, "tipo" to tipo, "detalle" to detalle, "datos" to datos))
    }

    private fun perder(id: Int, motivo: String) {
        if (id != idActual) return
        cerrarGatt()
        emitir(id, "desconectado", motivo)
    }

    @Suppress("DEPRECATION")
    private fun prepararCanal(id: Int, g: BluetoothGatt) {
        val canal = buscarCanal(g)
        if (canal == null) {
            val servicios = g.services.joinToString(", ") { nombreCorto(it.uuid) }
            perder(id, "sin_servicio:$servicios")
            return
        }
        val (lectura, esc) = canal
        escritura = esc
        g.setCharacteristicNotification(lectura, true)
        val cccd = lectura.getDescriptor(CCCD)
        if (cccd == null) {
            emitir(id, "conectado")
            return
        }
        val valor = if (lectura.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        } else {
            BluetoothGattDescriptor.ENABLE_INDICATION_VALUE
        }
        val ok = if (Build.VERSION.SDK_INT >= 33) {
            g.writeDescriptor(cccd, valor) == BluetoothStatusCodes.SUCCESS
        } else {
            cccd.value = valor
            g.writeDescriptor(cccd)
        }
        if (!ok) perder(id, "notificaciones")
    }

    private fun buscarCanal(g: BluetoothGatt): Pair<BluetoothGattCharacteristic, BluetoothGattCharacteristic>? {
        g.getService(NUS)?.let { s ->
            val tx = s.getCharacteristic(NUS_TX)
            val rx = s.getCharacteristic(NUS_RX)
            if (tx != null && rx != null) return tx to rx
        }
        g.getService(uuid16(0xFFE0))?.let { s ->
            val candidatas = listOfNotNull(s.getCharacteristic(uuid16(0xFFE1)), s.getCharacteristic(uuid16(0xFFE2)))
            val lectura = candidatas.firstOrNull(::notifica)
            val esc = candidatas.firstOrNull(::recibe)
            if (lectura != null && esc != null) return lectura to esc
        }
        for (s in g.services) {
            if (esEstandar(s.uuid)) continue
            val lectura = s.characteristics.firstOrNull(::notifica) ?: continue
            val esc = s.characteristics.firstOrNull(::recibe) ?: continue
            return lectura to esc
        }
        return null
    }

    private inner class Llamadas(private val id: Int) : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, nuevoEstado: Int) {
            principal.post {
                if (g != gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS && nuevoEstado == BluetoothProfile.STATE_CONNECTED) {
                    if (!g.discoverServices()) perder(id, "servicios")
                } else {
                    perder(id, "estado_$status")
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            principal.post {
                if (g != gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) prepararCanal(id, g) else perder(id, "servicios_$status")
            }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            principal.post {
                if (g != gatt) return@post
                if (status == BluetoothGatt.GATT_SUCCESS) emitir(id, "conectado") else perder(id, "notificaciones_$status")
            }
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            principal.post {
                if (g != gatt) return@post
                escribiendo = false
                escribirSiguiente()
            }
        }

        // Android 13 en adelante llama a esta; las versiones anteriores, a la de abajo
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            recibir(g, value.copyOf())
        }

        @Deprecated("Android 12 y anteriores")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            recibir(g, c.value?.copyOf() ?: return)
        }

        private fun recibir(g: BluetoothGatt, datos: ByteArray) {
            principal.post {
                if (g == gatt) emitir(id, "datos", datos = datos)
            }
        }
    }

    companion object {
        private const val TROZO = 20
        private val CCCD: UUID = uuid16(0x2902)
        private val NUS: UUID = UUID.fromString("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        private val NUS_RX: UUID = UUID.fromString("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        private val NUS_TX: UUID = UUID.fromString("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
        private const val BASE_SIG = "-0000-1000-8000-00805f9b34fb"

        private fun uuid16(v: Int): UUID = UUID.fromString("0000" + "%04x".format(Locale.ROOT, v) + BASE_SIG)

        private fun corto(u: UUID): Int? {
            val s = u.toString()
            if (!s.startsWith("0000") || !s.endsWith(BASE_SIG)) return null
            return s.substring(4, 8).toInt(16)
        }

        private fun nombreCorto(u: UUID): String = corto(u)?.let { "%04X".format(Locale.ROOT, it) } ?: u.toString()

        // GAP, GATT, información del dispositivo, batería...: no son el canal serial
        private fun esEstandar(u: UUID): Boolean = corto(u)?.let { it in 0x1800..0x18FF } ?: false

        private fun notifica(c: BluetoothGattCharacteristic): Boolean =
            c.properties and (BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_INDICATE) != 0

        private fun recibe(c: BluetoothGattCharacteristic): Boolean =
            c.properties and (BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE) != 0
    }
}
